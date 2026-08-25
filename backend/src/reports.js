// ============================================================
// TaxiCount - Fase 5: generación de informes (Excel + PDF).
// Consulta + agrupación por conductor, construcción de los ficheros y
// una caché en memoria con expiración. Separado de server.js para testear.
// ============================================================
import ExcelJS from 'exceljs';
import PdfPrinter from 'pdfmake';

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
    f.client || '', f.excludeClient || '',
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

  return { tenantName: tenant?.name || 'TaxiCount', startDate, endDate, transactions, groups };
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

const fmtDate = (iso) => new Date(iso).toISOString().slice(0, 10);
const fmtTime = (iso) => new Date(iso).toISOString().slice(11, 16); // HH:MM (UTC)
const tipoLabel = (t) => (t === 'income' ? 'Ingreso' : 'Gasto');
const money = (n) => Number(n).toFixed(2);

// Concepto legible: carrera => "origen → destino (km)"; gasto => categoría.
function concepto(t) {
  if (t.type === 'income') {
    const o = (t.origin || '').trim();
    const d = (t.destination || '').trim();
    let s = o || d ? `${o || '—'} → ${d || '—'}` : 'Carrera';
    if (t.odometer_km != null) s += ` (${t.odometer_km} km)`;
    return s;
  }
  return catDisplay(t);
}
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
  { header: 'Método de pago', key: 'pago', width: 14 },
  { header: 'Descripción', key: 'descripcion', width: 28 },
];

const rowFor = (t) => ({
  fecha: fmtDate(t.created_at),
  hora: fmtTime(t.created_at),
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
function orderedDetail(txs) {
  const income = txs.filter((t) => t.type === 'income');
  const expense = txs.filter((t) => t.type !== 'income');
  const byDate = (a, b) => String(a.created_at).localeCompare(String(b.created_at));

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

export async function buildExcel(data) {
  const wb = new ExcelJS.Workbook();
  wb.creator = 'TaxiCount';
  wb.created = new Date();

  const used = new Set();
  for (const [, g] of data.groups) {
    const ws = wb.addWorksheet(sheetName(g.name || g.email, used));
    ws.columns = COLS;
    ws.getColumn('importe').numFmt = MONEY_FMT;
    ws.getRow(1).font = { bold: true };
    for (const t of orderedDetail(g.txs)) {
      const row = ws.addRow(t ? rowFor(t) : {});
      if (t && t.type !== 'income') row.getCell('importe').font = { color: { argb: RED_ARGB } };
    }
    addTotals(ws, g.txs);
  }

  // Pestaña consolidada (todas las transacciones, con columna Conductor)
  const cws = wb.addWorksheet('Consolidado');
  cws.columns = [{ header: 'Conductor', key: 'conductor', width: 22 }, ...COLS];
  cws.getColumn('importe').numFmt = MONEY_FMT;
  cws.getRow(1).font = { bold: true };
  for (const t of orderedDetail(data.transactions)) {
    if (!t) { cws.addRow({}); continue; }
    const u = t.users || {};
    const row = cws.addRow({ conductor: u.name || u.email || '', ...rowFor(t) });
    if (t.type !== 'income') row.getCell('importe').font = { color: { argb: RED_ARGB } };
  }
  addTotals(cws, data.transactions);

  const buf = await wb.xlsx.writeBuffer();
  return Buffer.from(buf);
}

// ---------------- PDF ----------------
function detailTable(txs) {
  const body = [
    [
      { text: 'Fecha', bold: true },
      { text: 'Concepto', bold: true },
      { text: 'Cliente', bold: true },
      { text: 'Importe', bold: true },
      { text: 'Tipo', bold: true },
      { text: 'Pago', bold: true },
    ],
  ];
  // Mismo orden que el Excel: ingresos agrupados por cliente (Particular primero),
  // fila en blanco entre grupos, y los gastos al final; null = fila en blanco.
  for (const t of orderedDetail(txs)) {
    if (!t) { body.push([' ', '', '', '', '', '']); continue; }
    // Solo la cifra (€) de los gastos va en rojo.
    const amount = t.type !== 'income'
      ? { text: `${money(t.amount)} €`, color: RED_HEX }
      : `${money(t.amount)} €`;
    body.push([
      `${fmtDate(t.created_at)} ${fmtTime(t.created_at)}`,
      concepto(t),
      clienteLabel(t),
      amount,
      tipoLabel(t.type),
      t.payment_method || '',
    ]);
  }
  return {
    table: { headerRows: 1, widths: ['auto', '*', 'auto', 'auto', 'auto', 'auto'], body },
    margin: [0, 4, 0, 12],
  };
}

// Resumen ampliado para el PDF, IGUAL que el Excel (addTotals): primero los
// GASTOS con categoría · método de pago en la misma línea, luego los INGRESOS por
// método, y el balance. Todo en negrita. Tabla de 2 columnas sin bordes.
function summaryBlock(txs) {
  const t = totals(txs);
  const rows = [];
  const row = (label, val, red) =>
    rows.push([
      { text: label, bold: true },
      { text: val === undefined ? '' : `${money(val)} €`, bold: true, alignment: 'right', color: (red && val !== undefined) ? RED_HEX : undefined },
    ]);
  // Gastos primero (en rojo): categoría · método de pago.
  const expCombo = groupSum(txs, 'expense',
    (x) => `${catLabel(expenseCatKey(x))} · ${payLabel(x.payment_method || '')}`);
  if (expCombo.size) {
    row('Gastos (categoría · método de pago)', undefined, true);
    for (const [label, v] of expCombo) row(`   ${label}`, v, true);
  }
  row('TOTAL Gastos', t.expense, true);
  // Ingresos por método de pago (debajo de los gastos).
  const incByPay = orderPay(groupSum(txs, 'income', (x) => x.payment_method || ''));
  if (incByPay.length) {
    row('Ingresos por método de pago');
    for (const [label, v] of incByPay) row(`   ${label}`, v);
  }
  row('TOTAL Ingresos', t.income);
  row('BALANCE (Ingresos − Gastos)', t.balance);
  return { table: { widths: ['*', 'auto'], body: rows }, layout: 'noBorders', margin: [0, 4, 0, 12] };
}

export function buildPdf(data) {
  const printer = new PdfPrinter(FONTS);
  const range =
    data.startDate || data.endDate
      ? `${data.startDate ? fmtDate(data.startDate) : '—'} a ${data.endDate ? fmtDate(data.endDate) : '—'}`
      : 'Todo el periodo';

  const content = [
    { text: 'Informe TaxiCount', style: 'h1' },
    { text: `Flota: ${data.tenantName}`, margin: [0, 2, 0, 0] },
    { text: `Rango de fechas: ${range}`, margin: [0, 2, 0, 8] },

    { text: 'Resumen', style: 'h2' },
    summaryBlock(data.transactions),

    { text: 'Detalle por conductor', style: 'h2' },
  ];

  if (data.groups.size === 0) {
    content.push({ text: 'No hay transacciones para los filtros seleccionados.', italics: true });
  } else {
    for (const [, g] of data.groups) {
      content.push({ text: g.name, style: 'h3', margin: [0, 6, 0, 0] });
      content.push(detailTable(g.txs));
      content.push(summaryBlock(g.txs));
    }
  }

  const docDefinition = {
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
