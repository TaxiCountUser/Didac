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
  // Gasto "Otros" con texto libre: mostramos lo que escribió el usuario (ITV…).
  if (t.category === 'otros' && t.description && t.description.trim()) return t.description.trim();
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
  categoria: t.type === 'income' ? '' : (t.category || ''),
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

// Resumen ampliado al final de cada hoja (todo en negrita): ingresos y gastos
// desglosados por método de pago, gastos también por categoría, y el balance.
function addTotals(ws, txs) {
  const t = totals(txs);
  const bold = { bold: true };
  const line = (fecha, importe) => {
    const row = importe === undefined ? ws.addRow({ fecha }) : ws.addRow({ fecha, importe });
    row.font = bold;
  };
  ws.addRow({});

  // Ingresos por método de pago -> TOTAL Ingresos.
  const incByPay = orderPay(groupSum(txs, 'income', (x) => x.payment_method || ''));
  if (incByPay.length) {
    line('INGRESOS POR MÉTODO DE PAGO');
    for (const [label, v] of incByPay) line(`  ${label}`, v);
  }
  line('TOTAL Ingresos', t.income);

  // Gastos por método de pago y por categoría -> TOTAL Gastos.
  ws.addRow({});
  const expByPay = orderPay(groupSum(txs, 'expense', (x) => x.payment_method || ''));
  if (expByPay.length) {
    line('GASTOS POR MÉTODO DE PAGO');
    for (const [label, v] of expByPay) line(`  ${label}`, v);
  }
  const expByCat = groupSum(txs, 'expense', expenseCatKey);
  if (expByCat.size) {
    line('GASTOS POR CATEGORÍA');
    for (const [c, v] of expByCat) line(`  ${c}`, v);
  }
  line('TOTAL Gastos', t.expense);

  // Balance final.
  ws.addRow({});
  line('BALANCE (Ingresos − Gastos)', t.balance);
}

export async function buildExcel(data) {
  const wb = new ExcelJS.Workbook();
  wb.creator = 'TaxiCount';
  wb.created = new Date();

  const used = new Set();
  for (const [, g] of data.groups) {
    const ws = wb.addWorksheet(sheetName(g.name || g.email, used));
    ws.columns = COLS;
    ws.getRow(1).font = { bold: true };
    for (const t of g.txs) ws.addRow(rowFor(t));
    addTotals(ws, g.txs);
  }

  // Pestaña consolidada (todas las transacciones, con columna Conductor)
  const cws = wb.addWorksheet('Consolidado');
  cws.columns = [{ header: 'Conductor', key: 'conductor', width: 22 }, ...COLS];
  cws.getRow(1).font = { bold: true };
  for (const t of data.transactions) {
    const u = t.users || {};
    cws.addRow({ conductor: u.name || u.email || '', ...rowFor(t) });
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
  for (const t of txs) {
    body.push([
      `${fmtDate(t.created_at)} ${fmtTime(t.created_at)}`,
      concepto(t),
      clienteLabel(t),
      `${money(t.amount)} €`,
      tipoLabel(t.type),
      t.payment_method || '',
    ]);
  }
  return {
    table: { headerRows: 1, widths: ['auto', '*', 'auto', 'auto', 'auto', 'auto'], body },
    margin: [0, 4, 0, 12],
  };
}

// Resumen ampliado (mismo desglose que el Excel) para el PDF: ingresos y gastos
// por método de pago, gastos por categoría y balance. Todo en negrita. Tabla de
// 2 columnas sin bordes (etiqueta | importe).
function summaryBlock(txs) {
  const t = totals(txs);
  const rows = [];
  const row = (label, val) =>
    rows.push([
      { text: label, bold: true },
      { text: val === undefined ? '' : `${money(val)} €`, bold: true, alignment: 'right' },
    ]);
  const incByPay = orderPay(groupSum(txs, 'income', (x) => x.payment_method || ''));
  if (incByPay.length) {
    row('Ingresos por método de pago');
    for (const [label, v] of incByPay) row(`   ${label}`, v);
  }
  row('TOTAL Ingresos', t.income);
  const expByPay = orderPay(groupSum(txs, 'expense', (x) => x.payment_method || ''));
  if (expByPay.length) {
    row('Gastos por método de pago');
    for (const [label, v] of expByPay) row(`   ${label}`, v);
  }
  const expByCat = groupSum(txs, 'expense', expenseCatKey);
  if (expByCat.size) {
    row('Gastos por categoría');
    for (const [c, v] of expByCat) row(`   ${c}`, v);
  }
  row('TOTAL Gastos', t.expense);
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
