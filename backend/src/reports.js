// ============================================================
// TaxiCount - Fase 5: generación de informes (Excel + PDF).
// Consulta + agrupación por conductor, construcción de los ficheros y
// una caché en memoria con expiración. Separado de server.js para testear.
// ============================================================
import ExcelJS from 'exceljs';
import PdfPrinter from 'pdfmake';
import {
  buildDays, daysTotals, segmentsLabel, weekdayOf, longDate, dmy, kmFmt, workedLabel, SOURCE_LABEL,
} from './report_days.js';
import { fmtDuration } from './workday.js';

const FONTS = {
  Helvetica: {
    normal: 'Helvetica',
    bold: 'Helvetica-Bold',
    italics: 'Helvetica-Oblique',
    bolditalics: 'Helvetica-BoldOblique',
  },
};

// ---------------- Caché (10 min) ----------------
const CACHE_TTL_MS = 10 * 60 * 1000;
const cache = new Map();

export function cacheKey(format, f = {}) {
  return [
    format, f.tenantId, f.startDate || '', f.endDate || '', f.driverId || '', f.vehicleId || '',
    f.client || '', f.excludeClient || '', safeTz(f.tz),
    (f.clients || []).join('+'), (f.excludeClients || []).join('+'),
  ].join('|');
}
export function getCached(key) {
  const e = cache.get(key);
  if (!e) return null;
  if (Date.now() > e.expires) {
    cache.delete(key);
    return null;
  }
  return e;
}
export function setCached(key, value) {
  cache.set(key, { ...value, expires: Date.now() + CACHE_TTL_MS });
}
export function clearReportCache() {
  cache.clear();
}

// ---------------- Datos ----------------
export async function fetchReportData(supabase, filters = {}) {
  const { tenantId, startDate, endDate, driverId, vehicleId, client, excludeClient, clients, excludeClients } = filters;
  // Admite una empresa (client/excludeClient) o varias (clients/excludeClients).
  const incl = (Array.isArray(clients) && clients.length) ? clients : (client ? [client] : []);
  const excl = (Array.isArray(excludeClients) && excludeClients.length) ? excludeClients : (excludeClient ? [excludeClient] : []);
  // En el filtro or() de PostgREST los comodines son '*' (no '%') y la coma/los
  // paréntesis separan condiciones: los limpiamos del valor.
  const orSafe = (s) => String(s).replace(/[,()*]/g, ' ').trim();

  let q = supabase
    .from('transactions')
    .select('*, users:user_id(name, email), vehicles:vehicle_id(license_plate, model)')
    .eq('tenant_id', tenantId);
  if (driverId) q = q.eq('user_id', driverId);
  if (vehicleId) q = q.eq('vehicle_id', vehicleId);
  if (startDate) q = q.gte('created_at', startDate);
  if (endDate) q = q.lt('created_at', endDate);
  // Solo estas empresas (cualquiera de ellas).
  if (incl.length) {
    q = q.or(incl.map((c) => `client_name.ilike.*${orSafe(c)}*`).join(','));
  }
  // Excluir estas empresas: ninguna de ellas aparece.
  for (const c of excl) {
    q = q.not('client_name', 'ilike', `%${c}%`);
  }
  q = q.order('created_at', { ascending: true });

  const { data, error } = await q;
  if (error) throw new Error(error.message);
  const transactions = data || [];

  const { data: tenant } = await supabase.from('tenants').select('name').eq('id', tenantId).single();

  // Agrupar por conductor
  const groups = new Map();
  for (const t of transactions) {
    const u = t.users || {};
    const name = u.name && u.name.length ? u.name : u.email || 'Conductor';
    if (!groups.has(t.user_id)) groups.set(t.user_id, { name, email: u.email || '', txs: [] });
    groups.get(t.user_id).txs.push(t);
  }

  // Horario y km de cada día (registro de jornada + lecturas de «Iniciar/Finalizar
  // día»). Best-effort: si falla, el informe sale igual sin el resumen por día.
  const range = (q, col) => {
    let r = q.eq('tenant_id', tenantId);
    if (driverId) r = r.eq('user_id', driverId);
    if (vehicleId) r = r.eq('vehicle_id', vehicleId);
    if (startDate) r = r.gte(col, startDate);
    if (endDate) r = r.lt(col, endDate);
    return r;
  };
  let shifts = [];
  let readings = [];
  try {
    const { data: s } = await range(supabase.from('work_shifts')
      .select('*, work_events(*), users:user_id(name, email)'), 'started_at');
    shifts = s || [];
  } catch { /* sin registro de jornada */ }
  try {
    const { data: r } = await range(supabase.from('odometer_readings')
      .select('user_id, vehicle_id, reading_km, taken_at, users:user_id(name, email)'), 'taken_at');
    readings = r || [];
  } catch { /* sin lecturas */ }

  const tz = safeTz(filters.tz);
  return {
    tenantName: tenant?.name || 'TaxiCount', startDate, endDate, transactions, groups, tz,
    days: buildDays({ transactions, shifts, readings, tz }),
    singleDay: isSingleDay(startDate, endDate, tz),
  };
}

// ¿El informe es de UN solo día (en la zona de quien lo pide)? Entonces el detalle
// va por orden de HORA y arriba sale el resumen de la jornada.
export function isSingleDay(startDate, endDate, tz) {
  if (!startDate || !endDate) return false;
  const end = new Date(endDate).getTime() - 1;
  if (!(end > new Date(startDate).getTime())) return false;
  return fmtDate(startDate, tz) === fmtDate(end, tz);
}

function totals(txs) {
  let income = 0;
  let expense = 0;
  for (const t of txs) {
    const a = Number(t.amount);
    if (t.type === 'income') income += a;
    else expense += a;
  }
  return { income, expense, balance: income - expense };
}

// Fecha y hora en la ZONA HORARIA DE QUIEN PIDE EL INFORME, la misma con la que
// la app/web le enseña sus carreras (hora del móvil/navegador): así el Excel/PDF
// dicen EXACTAMENTE la misma hora que la app (antes salían en UTC: 1–2 h menos, y
// una carrera a las 00:30 salía con el día anterior). La app manda `tz` (IANA,
// p. ej. 'Europe/Madrid', 'Atlantic/Canary'); si falta o no es válida, España.
export const DEFAULT_TZ = 'Europe/Madrid';
export function safeTz(tz) {
  if (typeof tz !== 'string' || !tz || tz.length > 64) return DEFAULT_TZ;
  try { new Intl.DateTimeFormat('en', { timeZone: tz }); return tz; } catch { return DEFAULT_TZ; }
}
const _fmts = new Map();
function fmtsFor(tz) {
  const z = safeTz(tz);
  if (!_fmts.has(z)) {
    _fmts.set(z, {
      date: new Intl.DateTimeFormat('sv-SE', { timeZone: z, year: 'numeric', month: '2-digit', day: '2-digit' }),
      time: new Intl.DateTimeFormat('es-ES', { timeZone: z, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }),
    });
  }
  return _fmts.get(z);
}
// Formato AAAA-MM-DD / HH:MM.
export const fmtDate = (iso, tz) => fmtsFor(tz).date.format(new Date(iso));
export const fmtTime = (iso, tz) => fmtsFor(tz).time.format(new Date(iso));
// Fecha/hora de una CARRERA tal como se apuntó (mig. 091): si tiene la diferencia
// horaria del móvil al apuntarla (utc_offset_min), se usa ESA (una carrera de las
// 08:15 en México sale a las 08:15 aunque el informe se pida desde España); si no
// (carreras antiguas), la zona de quien pide el informe.
function txShifted(t) {
  const off = t.utc_offset_min;
  if (off === null || off === undefined || !Number.isFinite(Number(off))) return null;
  return new Date(new Date(t.created_at).getTime() + Number(off) * 60000);
}
export const txDate = (t, tz) => { const w = txShifted(t); return w ? fmtDate(w, 'UTC') : fmtDate(t.created_at, tz); };
export const txTime = (t, tz) => { const w = txShifted(t); return w ? fmtTime(w, 'UTC') : fmtTime(t.created_at, tz); };
const tipoLabel = (t) => (t === 'income' ? 'Ingreso' : 'Gasto');
// Importe con formato español, igual que el Excel: 1.234,50 €.
const _fEur = new Intl.NumberFormat('es-ES', { minimumFractionDigits: 2, maximumFractionDigits: 2, useGrouping: true });
const eur = (n) => `${_fEur.format(Number(n))} €`;

// Categoría MOSTRADA de un gasto en el listado: "Otros" con texto libre sale como
// "otros (ITV)" (categoría + lo que escribió el usuario). En el resumen/total, en
// cambio, se agrupa por el texto libre a secas ("ITV") vía expenseCatKey.
function catDisplay(t) {
  if (t.type === 'income') return '';
  if (t.category === 'otros' && t.description && t.description.trim()) return `otros (${t.description.trim()})`;
  return t.category || '';
}
// Cliente: en carreras, empresa nombrada (1ª letra mayúscula) o "Particular".
const capFirst = (s) => (s ? s.charAt(0).toUpperCase() + s.slice(1) : s);
const clienteLabel = (t) =>
  t.type === 'income'
    ? (t.client_name && t.client_name.trim() ? capFirst(t.client_name.trim()) : 'Particular')
    : '';

// Saneado del nombre de pestaña Excel (<=31 chars, sin []:*?/\), único.
function sheetName(raw, used) {
  let base = String(raw).replace(/[[\]:*?/\\]/g, ' ').trim().slice(0, 31) || 'Conductor';
  let name = base;
  let i = 2;
  while (used.has(name)) {
    const suffix = ` (${i++})`;
    name = base.slice(0, 31 - suffix.length) + suffix;
  }
  used.add(name);
  return name;
}

// ---------------- Excel ----------------
const COLS = [
  { header: 'Fecha', key: 'fecha', width: 12 },
  { header: 'Hora', key: 'hora', width: 8 },
  { header: 'Importe', key: 'importe', width: 11 },
  { header: 'Tipo', key: 'tipo', width: 9 },
  { header: 'Categoría', key: 'categoria', width: 14 },
  { header: 'Origen', key: 'origen', width: 18 },
  { header: 'Destino', key: 'destino', width: 18 },
  { header: 'Km', key: 'km', width: 10 },
  { header: 'Cliente', key: 'cliente', width: 18 },
  { header: 'Método de pago', key: 'pago', width: 16 },
  { header: 'Descripción', key: 'descripcion', width: 28 },
];

const rowFor = (t, tz) => ({
  fecha: txDate(t, tz),
  hora: txTime(t, tz),
  importe: Number(t.amount),
  tipo: tipoLabel(t.type),
  categoria: catDisplay(t),
  origen: t.origin || '',
  destino: t.destination || '',
  km: t.odometer_km ?? '',
  cliente: clienteLabel(t),
  pago: t.payment_method || '',
  descripcion: t.description || '',
});

// Etiquetas y orden de los métodos de pago (los del formulario de la app).
const PAY_LABELS = { efectivo: 'Efectivo', tarjeta: 'Tarjeta', bizum: 'Bizum', credito: 'Crédito' };
const PAY_ORDER = ['efectivo', 'tarjeta', 'bizum', 'credito'];
const payLabel = (m) => PAY_LABELS[m] || (m ? capFirst(m) : 'Sin método');

// Suma importes de las transacciones de un tipo agrupadas por keyFn.
// Devuelve pares [clave, total] con los métodos conocidos primero (PAY_ORDER)
// y el resto por orden de aparición.
function groupSum(txs, type, keyFn) {
  const m = new Map();
  for (const t of txs) {
    if (t.type !== type) continue;
    const k = keyFn(t);
    m.set(k, (m.get(k) || 0) + Number(t.amount));
  }
  return m;
}
function orderPay(map) {
  const out = [];
  for (const k of PAY_ORDER) if (map.has(k)) out.push([payLabel(k), map.get(k)]);
  for (const [k, v] of map) if (!PAY_ORDER.includes(k)) out.push([payLabel(k), v]);
  return out;
}

// Clave de categoría de un gasto para el desglose: en "Otros" con texto libre,
// agrupamos por ese texto (p. ej. "ITV") en vez de meterlo todo en "otros".
const expenseCatKey = (x) =>
  (x.category === 'otros' && x.description && x.description.trim())
    ? x.description.trim()
    : (x.category || 'Sin categoría');

// Etiqueta legible de categoría (las claves llegan crudas: 'carga_electrica'…).
const catLabel = (c) => capFirst(String(c || 'Sin categoría').replace(/_/g, ' '));

// Resumen ampliado al final de cada hoja (todo en negrita): primero los GASTOS
// con categoría + método de pago en la MISMA línea, y debajo los INGRESOS por
// método de pago; cierra el balance.
function addTotals(ws, txs) {
  const t = totals(txs);
  const line = (fecha, importe, red) => {
    const row = importe === undefined ? ws.addRow({ fecha }) : ws.addRow({ fecha, importe });
    row.font = { bold: true };
    // Solo la cifra (€) de los gastos va en rojo; la etiqueta se queda negra.
    if (red && importe !== undefined) row.getCell('importe').font = { bold: true, color: { argb: RED_ARGB } };
  };
  ws.addRow({});

  // GASTOS primero (en rojo): categoría · método en la misma línea -> TOTAL Gastos.
  const expCombo = groupSum(txs, 'expense',
    (x) => `${catLabel(expenseCatKey(x))} · ${payLabel(x.payment_method || '')}`);
  if (expCombo.size) {
    line('GASTOS (categoría · método de pago)', undefined, true);
    for (const [label, v] of expCombo) line(`  ${label}`, v, true);
  }
  line('TOTAL Gastos', t.expense, true);

  // INGRESOS por método de pago (debajo de los gastos) -> TOTAL Ingresos.
  ws.addRow({});
  const incByPay = orderPay(groupSum(txs, 'income', (x) => x.payment_method || ''));
  if (incByPay.length) {
    line('INGRESOS POR MÉTODO DE PAGO');
    for (const [label, v] of incByPay) line(`  ${label}`, v);
  }
  line('TOTAL Ingresos', t.income);

  // Balance final.
  ws.addRow({});
  line('BALANCE (Ingresos − Gastos)', t.balance);
}

// Ordena las filas de detalle: primero los INGRESOS agrupados por cliente
// (Particular el primero, luego el resto alfabético), cada grupo separado por una
// fila en blanco y ordenado por fecha/hora dentro del grupo; al final los GASTOS,
// ordenados por fecha. Devuelve una lista donde null = fila en blanco.
// byHour (informe de UN día): todo junto por orden de hora, como pasó el día.
function orderedDetail(txs, byHour = false) {
  const byDate = (a, b) => String(a.created_at).localeCompare(String(b.created_at));
  if (byHour) return [...txs].sort(byDate);
  const income = txs.filter((t) => t.type === 'income');
  const expense = txs.filter((t) => t.type !== 'income');

  const groups = new Map(); // etiqueta de cliente -> transacciones
  for (const t of income) {
    const label = clienteLabel(t) || 'Particular';
    if (!groups.has(label)) groups.set(label, []);
    groups.get(label).push(t);
  }
  const labels = [...groups.keys()].sort((a, b) => {
    if (a === 'Particular') return -1;
    if (b === 'Particular') return 1;
    return a.localeCompare(b, 'es', { sensitivity: 'base' });
  });

  const out = [];
  labels.forEach((label, i) => {
    if (i > 0) out.push(null); // fila en blanco entre clientes
    groups.get(label).sort(byDate);
    for (const t of groups.get(label)) out.push(t);
  });
  if (expense.length) {
    if (out.length) out.push(null); // fila en blanco antes de los gastos
    expense.sort(byDate);
    for (const t of expense) out.push(t);
  }
  return out;
}

// Formato de celda para los importes: numérico con símbolo de moneda. Hoy toda
// la app opera en EUR (mercado España, Stripe en €); si se internacionaliza,
// esto pasaría a depender de la moneda del tenant.
const MONEY_FMT = '#,##0.00" €"';
// Rojo para los gastos (Excel: ARGB; PDF: hex).
const RED_ARGB = 'FFC00000';
const RED_HEX = '#C00000';

// Aspecto de TABLA igual que el PDF: cabecera en gris con línea gruesa debajo y
// una línea fina gris entre filas del detalle (también las de separación). Solo
// el detalle (filas 1..lastRow); el resumen de debajo queda sin líneas.
const HEAD_FILL = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFEEEEEE' } };
const LINE = { style: 'thin', color: { argb: 'FFBDBDBD' } };
function styleTable(ws, lastRow, headRow = 1) {
  const n = ws.columns.length;
  for (let r = headRow; r <= lastRow; r++) {
    const row = ws.getRow(r);
    for (let c = 1; c <= n; c++) {
      const cell = row.getCell(c);
      if (r === headRow) {
        cell.fill = HEAD_FILL;
        cell.font = { bold: true };
        cell.border = { bottom: { style: 'medium', color: { argb: 'FF000000' } } };
      } else {
        cell.border = { bottom: LINE };
      }
    }
  }
}

// Impresión de una hoja: horizontal, ajustada al ancho de 1 página, cabecera
// repetida en cada página y SIN la columna Descripción (la última): se ve en
// pantalla pero queda fuera del área de impresión.
function setupPrint(ws, headRow = 1, lastPrinted = ws.columns.length - 1 /* la última es Descripción */) {
  const colLetter = ws.getColumn(lastPrinted).letter;
  ws.pageSetup = {
    paperSize: 9, // A4
    orientation: 'landscape',
    fitToPage: true, fitToWidth: 1, fitToHeight: 0,
    printArea: `A1:${colLetter}${Math.max(ws.rowCount, 1)}`,
    printTitlesRow: `${headRow}:${headRow}`,
    margins: { left: 0.4, right: 0.4, top: 0.5, bottom: 0.5, header: 0.3, footer: 0.3 },
  };
}

// ---------------- Resumen del día / Resumen diario ----------------
// Día de un conductor en un informe de UN día (el único que tiene).
const dayOfDriver = (data, uid) => data.days?.get(uid)?.days?.[0] || null;
const kmText = (d) => {
  if (d.km === null || d.km === undefined) return 'sin datos de km';
  const range = d.kmStart != null && d.kmEnd != null ? `de ${kmFmt(d.kmStart)} a ${kmFmt(d.kmEnd)} · ` : '';
  return `${range}${kmFmt(d.km)} km`;
};
// Líneas del «Resumen de la jornada» de un conductor (encima de su tabla).
function dayLines(d, name) {
  if (!d) return [];
  return [
    { text: `${longDate(d.date)} · ${name}`, big: true },
    { text: `Horario: ${segmentsLabel(d.segments) || '—'}   (${SOURCE_LABEL[d.source] || ''})` },
    { text: `Horas trabajadas: ${workedLabel(d) || '—'}${d.pausedMs ? `   ·   En pausa: ${fmtDuration(d.pausedMs)}` : ''}` },
    { text: `Kilómetros: ${kmText(d)}` },
    { text: `Carreras: ${d.rides}   ·   Ingresos: ${eur(d.income)}   ·   Gastos: ${eur(d.expense)}` },
  ];
}
// Columnas de la hoja «Resumen diario» (días trabajados del periodo).
const DAY_COLS = [
  { header: 'Conductor', key: 'conductor', width: 22 },
  { header: 'Fecha', key: 'fecha', width: 11 },
  { header: 'Día', key: 'dia', width: 11 },
  { header: 'Horario', key: 'horario', width: 28 },
  { header: 'Horas trabajadas', key: 'horas', width: 15 },
  { header: 'Km inicio', key: 'kmini', width: 10 },
  { header: 'Km fin', key: 'kmfin', width: 10 },
  { header: 'Km', key: 'km', width: 8 },
  { header: 'Carreras', key: 'carreras', width: 9 },
  { header: 'Ingresos', key: 'ingresos', width: 12 },
  { header: 'Gastos', key: 'gastos', width: 12 },
  { header: 'Horario según', key: 'segun', width: 30 },
];
const dayRow = (name, d) => ({
  conductor: name, fecha: dmy(d.date), dia: weekdayOf(d.date), horario: segmentsLabel(d.segments),
  horas: workedLabel(d), kmini: d.kmStart ?? '', kmfin: d.kmEnd ?? '', km: d.km ?? '',
  carreras: d.rides, ingresos: d.income, gastos: d.expense, segun: SOURCE_LABEL[d.source] || '',
});
const dayTotalRow = (name, days) => {
  const t = daysTotals(days);
  return {
    conductor: `TOTAL ${name}`, fecha: `${t.days} ${t.days === 1 ? 'día' : 'días'}`,
    horas: fmtDuration(t.worked), km: days.some((d) => d.km != null) ? t.km : '',
    carreras: t.rides, ingresos: t.income, gastos: t.expense,
  };
};

// Cabecera de hoja: líneas de resumen (fusionadas a lo ancho) + fila de títulos.
// Sin líneas = la tabla empieza en la fila 1, como siempre. Devuelve la fila de títulos.
function sheetStart(ws, cols, lines = []) {
  if (!lines.length) { ws.columns = cols; return 1; }
  ws.columns = cols.map(({ key, width }) => ({ key, width }));
  const last = ws.getColumn(Math.max(cols.length - 1, 1)).letter;
  for (const l of lines) {
    const row = ws.addRow([l.text]);
    ws.mergeCells(`A${row.number}:${last}${row.number}`);
    row.getCell(1).font = l.big ? { bold: true, size: 13 } : { bold: false };
  }
  ws.addRow([]);
  return ws.addRow(cols.map((c) => c.header)).number;
}

// Tipo de informe según el rango pedido (en la zona de quien lo pide): da nombre
// a la hoja «Resumen general (…)» del Excel y a la sección del PDF.
export function periodKind(startDate, endDate, tz) {
  if (!startDate || !endDate) return 'del periodo';
  const d0 = fmtDate(startDate, tz);
  const d1 = fmtDate(new Date(endDate).getTime() - 1, tz);
  if (d0 === d1) return 'diario';
  const days = Math.round((Date.parse(`${d1}T00:00:00Z`) - Date.parse(`${d0}T00:00:00Z`)) / 86400000) + 1;
  const dow = new Date(`${d0}T12:00:00Z`).getUTCDay(); // 1 = lunes
  if (days === 7 && dow === 1) return 'semanal';
  const lastOfMonth = (d) => {
    const [y, m] = d.split('-').map(Number);
    return new Date(Date.UTC(y, m, 0)).getUTCDate();
  };
  if (d0.slice(0, 7) === d1.slice(0, 7) && d0.endsWith('-01') && Number(d1.slice(8)) === lastOfMonth(d1)) return 'mensual';
  if (d0.slice(0, 4) === d1.slice(0, 4) && d0.endsWith('-01-01') && d1.endsWith('-12-31')) return 'anual';
  return 'del periodo';
}
export const generalTitle = (data) => `Resumen general (${periodKind(data.startDate, data.endDate, data.tz)})`;
const DAYS_SHEET = 'Resumen diario conductores';

// Orden de las hojas (y de las secciones del PDF, siempre igual):
//   1. «Resumen general (diario/semanal/mensual/anual/del periodo)»: la hoja de
//      la EMPRESA, por CLIENTE (desde aquí se factura), con columna Conductor.
//   2. Una hoja por conductor (los del informe: uno o todos), por FECHA y hora;
//      en el informe de un día, con el resumen de su jornada encima.
//   3. «Resumen diario conductores»: cada día trabajado (horario, horas, km,
//      carreras, ingresos, gastos) y el total de cada conductor.
export async function buildExcel(data) {
  const wb = new ExcelJS.Workbook();
  wb.creator = 'TaxiCount';
  wb.created = new Date();
  const one = !!data.singleDay;
  const general = generalTitle(data);

  // 1. Resumen general (todas las transacciones, con columna Conductor).
  const cws = wb.addWorksheet(general);
  const ccols = [{ header: 'Conductor', key: 'conductor', width: 22 }, ...COLS];
  const chead = sheetStart(cws, ccols, []);
  cws.getColumn('importe').numFmt = MONEY_FMT;
  cws.getRow(chead).font = { bold: true };
  for (const t of orderedDetail(data.transactions)) {
    if (!t) { cws.addRow({}); continue; }
    const u = t.users || {};
    const row = cws.addRow({ conductor: u.name || u.email || '', ...rowFor(t, data.tz) });
    if (t.type !== 'income') row.getCell('importe').font = { color: { argb: RED_ARGB } };
  }
  styleTable(cws, cws.rowCount, chead);
  addTotals(cws, data.transactions);
  setupPrint(cws, chead);

  // 2. Una hoja por conductor, por fecha y hora.
  const used = new Set([general, DAYS_SHEET]);
  for (const [uid, g] of data.groups) {
    const ws = wb.addWorksheet(sheetName(g.name || g.email, used));
    const head = sheetStart(ws, COLS, one ? dayLines(dayOfDriver(data, uid), g.name) : []);
    ws.getColumn('importe').numFmt = MONEY_FMT;
    ws.getRow(head).font = { bold: true };
    for (const t of orderedDetail(g.txs, true)) {
      const row = ws.addRow(rowFor(t, data.tz));
      if (t.type !== 'income') row.getCell('importe').font = { color: { argb: RED_ARGB } };
    }
    styleTable(ws, ws.rowCount, head);
    addTotals(ws, g.txs);
    setupPrint(ws, head);
  }

  // 3. Resumen diario de los conductores del informe.
  if (data.days && data.days.size) {
    const dws = wb.addWorksheet(DAYS_SHEET);
    dws.columns = DAY_COLS;
    for (const k of ['ingresos', 'gastos']) dws.getColumn(k).numFmt = MONEY_FMT;
    const totals = [];
    let first = true;
    for (const [, u] of data.days) {
      if (!first) dws.addRow({});
      first = false;
      for (const d of u.days) {
        const row = dws.addRow(dayRow(u.name, d));
        if (d.expense > 0) row.getCell('gastos').font = { color: { argb: RED_ARGB } };
      }
      const tot = dws.addRow(dayTotalRow(u.name, u.days));
      tot.font = { bold: true };
      if (daysTotals(u.days).expense > 0) tot.getCell('gastos').font = { bold: true, color: { argb: RED_ARGB } };
      totals.push(tot.number);
    }
    styleTable(dws, dws.rowCount);
    for (const r of totals) {
      for (let c = 1; c <= DAY_COLS.length; c++) dws.getRow(r).getCell(c).fill = HEAD_FILL;
    }
    setupPrint(dws, 1, DAY_COLS.length);
  }

  const buf = await wb.xlsx.writeBuffer();
  return Buffer.from(buf);
}

// ---------------- PDF ----------------
// Tabla de detalle IGUAL que la hoja del Excel (mismas columnas y orden, mismos
// datos de rowFor) salvo la Descripción, que no se imprime. withDriver = columna
// Conductor delante (la del Resumen general).
const PDF_COLS = COLS.filter((c) => c.key !== 'descripcion');
// Fila-título que se REPITE arriba de cada página de la tabla: si una hoja ocupa
// varias páginas, cada página dice de qué hoja es («Pepe García · …»).
const runningTitle = (title, n) => [
  { text: title, colSpan: n, fontSize: 7, color: '#777777', margin: [0, 0, 0, 1] },
  ...Array.from({ length: n - 1 }, () => ({})),
];

function detailTable(txs, tz, withDriver = false, byHour = false, title = '') {
  const cols = withDriver ? [{ header: 'Conductor', key: 'conductor' }, ...PDF_COLS] : PDF_COLS;
  const body = [runningTitle(title, cols.length), cols.map((c) => ({ text: c.header, bold: true, fillColor: '#EEEEEE' }))];
  // Mismo orden que el Excel: ingresos agrupados por cliente (Particular primero),
  // fila en blanco entre grupos, y los gastos al final; null = fila en blanco.
  for (const t of orderedDetail(txs, byHour)) {
    if (!t) { body.push(cols.map(() => ' ')); continue; }
    const u = t.users || {};
    const r = { conductor: u.name || u.email || '', ...rowFor(t, tz) };
    body.push(cols.map((c) => {
      if (c.key === 'importe') {
        // Solo la cifra (€) de los gastos va en rojo.
        return { text: eur(r.importe), alignment: 'right', color: t.type !== 'income' ? RED_HEX : undefined };
      }
      if (c.key === 'km') return { text: String(r.km), alignment: 'right' };
      return String(r[c.key] ?? '');
    }));
  }
  // Origen/Destino/Cliente se reparten el ancho sobrante; el resto, a su medida.
  const flex = new Set(['origen', 'destino', 'cliente', 'conductor']);
  return {
    table: { headerRows: 2, widths: cols.map((c) => (flex.has(c.key) ? '*' : 'auto')), body },
    layout: 'lightHorizontalLines',
    fontSize: 8,
    margin: [0, 4, 0, 10],
  };
}

// Resumen para el PDF, IGUAL que el del Excel (addTotals): primero los GASTOS con
// categoría · método de pago en la misma línea, luego los INGRESOS por método y
// el balance, con las mismas líneas en blanco entre bloques. Todo en negrita y
// compacto (2 columnas estrechas, como en la hoja). Ojo: la fuente estándar del
// PDF (Helvetica) no tiene el signo "−" (U+2212): se usa el guion normal.
function summaryBlock(txs) {
  const t = totals(txs);
  const rows = [];
  const row = (label, val, red) =>
    rows.push([
      { text: label, bold: true, preserveLeadingSpaces: true },
      { text: val === undefined ? '' : eur(val), bold: true, alignment: 'right', color: (red && val !== undefined) ? RED_HEX : undefined },
    ]);
  const gap = () => rows.push([{ text: ' ', fontSize: 4 }, '']);
  const expCombo = groupSum(txs, 'expense',
    (x) => `${catLabel(expenseCatKey(x))} · ${payLabel(x.payment_method || '')}`);
  if (expCombo.size) {
    row('GASTOS (categoría · método de pago)', undefined, true);
    for (const [label, v] of expCombo) row(`   ${label}`, v, true);
  }
  row('TOTAL Gastos', t.expense, true);
  gap();
  const incByPay = orderPay(groupSum(txs, 'income', (x) => x.payment_method || ''));
  if (incByPay.length) {
    row('INGRESOS POR MÉTODO DE PAGO');
    for (const [label, v] of incByPay) row(`   ${label}`, v);
  }
  row('TOTAL Ingresos', t.income);
  gap();
  row('BALANCE (Ingresos - Gastos)', t.balance);
  return { table: { widths: [210, 70], body: rows }, layout: 'noBorders', margin: [0, 4, 0, 12] };
}

// Resumen de la jornada en el PDF (encima de la tabla): un recuadro gris claro.
function pdfLines(lines) {
  return {
    table: { widths: ['*'], body: [[{ stack: lines.map((l) => ({ text: l.text, bold: !!l.big, margin: [0, 1, 0, 1] })), fillColor: '#F5F5F5' }]] },
    layout: 'noBorders', margin: [0, 2, 0, 6],
  };
}
// Tabla del «Resumen diario» en el PDF (mismas columnas que la hoja del Excel).
const DAY_PDF_W = { conductor: '*', fecha: 42, dia: 40, horario: 105, horas: 50, kmini: 36, kmfin: 36, km: 26, carreras: 38, ingresos: 46, gastos: 46, segun: 90 };
function dayTable(days, title = '') {
  const body = [runningTitle(title, DAY_COLS.length), DAY_COLS.map((c) => ({ text: c.header, bold: true, fillColor: '#EEEEEE' }))];
  const cell = (c, r, bold) => {
    const v = r[c.key];
    if (c.key === 'ingresos' || c.key === 'gastos') {
      return { text: v === undefined || v === '' ? '' : eur(v), alignment: 'right', bold, color: (c.key === 'gastos' && v > 0) ? RED_HEX : undefined };
    }
    if (['kmini', 'kmfin', 'km', 'carreras'].includes(c.key)) return { text: v === '' || v == null ? '' : kmFmt(v), alignment: 'right', bold };
    return { text: String(v ?? ''), bold };
  };
  let first = true;
  for (const [, u] of days) {
    if (!first) body.push(DAY_COLS.map(() => ' '));
    first = false;
    for (const d of u.days) { const r = dayRow(u.name, d); body.push(DAY_COLS.map((c) => cell(c, r, false))); }
    const t = dayTotalRow(u.name, u.days);
    body.push(DAY_COLS.map((c) => ({ ...cell(c, t, true), fillColor: '#EEEEEE' })));
  }
  return {
    table: { headerRows: 2, widths: DAY_COLS.map((c) => DAY_PDF_W[c.key] || 'auto'), body },
    layout: 'lightHorizontalLines', fontSize: 8, margin: [0, 4, 0, 10],
  };
}

export function buildPdf(data) {
  const printer = new PdfPrinter(FONTS);
  const range =
    data.startDate || data.endDate
      ? `${data.startDate ? fmtDate(data.startDate, data.tz) : '—'} a ${data.endDate ? fmtDate(new Date(data.endDate).getTime() - 1, data.tz) : '—'}`
      : 'Todo el periodo';

  const content = [
    { text: 'Informe TaxiCount', style: 'h1' },
    { text: `Flota: ${data.tenantName}`, margin: [0, 2, 0, 0] },
    { text: `Rango de fechas: ${range}`, margin: [0, 2, 0, 8] },
  ];

  // Mismas secciones y en el MISMO orden que las hojas del Excel: Resumen
  // general → un apartado por conductor → Resumen diario conductores. Cada
  // apartado (= cada hoja del Excel) EMPIEZA EN PÁGINA NUEVA, aunque el anterior
  // deje media página en blanco, y su tabla repite arriba de cada página de qué
  // hoja es (por si ocupa más de una).
  if (data.groups.size === 0) {
    content.push({ text: 'No hay transacciones para los filtros seleccionados.', italics: true });
  } else {
    const one = !!data.singleDay;
    const general = generalTitle(data);
    const tag = (name) => `${name} · ${data.tenantName} · ${range}`;
    content.push({ text: `${general} · todos los conductores`, style: 'h2' });
    content.push(detailTable(data.transactions, data.tz, true, false, tag(general)));
    content.push(summaryBlock(data.transactions));
    for (const [uid, g] of data.groups) {
      content.push({ text: g.name, style: 'h2', pageBreak: 'before' });
      if (one) {
        // Mismo resumen que el Excel; el nombre ya va en el título de la sección.
        const L = dayLines(dayOfDriver(data, uid), g.name);
        if (L.length) { L[0] = { text: longDate(dayOfDriver(data, uid).date), big: true }; content.push(pdfLines(L)); }
      }
      content.push(detailTable(g.txs, data.tz, false, true, tag(g.name)));
      content.push(summaryBlock(g.txs));
    }
    if (data.days && data.days.size) {
      content.push({ text: DAYS_SHEET, style: 'h2', pageBreak: 'before' });
      content.push(dayTable(data.days, tag(DAYS_SHEET)));
    }
  }

  const docDefinition = {
    pageSize: 'A4',
    pageOrientation: 'landscape',
    pageMargins: [28, 28, 28, 34],
    footer: (page, pages) => ({ text: `${page} / ${pages}`, alignment: 'right', fontSize: 8, margin: [0, 8, 28, 0] }),
    defaultStyle: { font: 'Helvetica', fontSize: 9 },
    styles: {
      h1: { fontSize: 18, bold: true },
      h2: { fontSize: 13, bold: true, margin: [0, 8, 0, 4] },
      h3: { fontSize: 11, bold: true },
    },
    content,
  };

  return new Promise((resolve, reject) => {
    try {
      const doc = printer.createPdfKitDocument(docDefinition);
      const chunks = [];
      doc.on('data', (c) => chunks.push(c));
      doc.on('end', () => resolve(Buffer.concat(chunks)));
      doc.on('error', reject);
      doc.end();
    } catch (e) {
      reject(e);
    }
  });
}
