// ============================================================
// TaxiCount - Importador de Excel/CSV antiguo.
// Lee un fichero .xlsx o .csv y lo "adapta" reconociendo los nombres de columna
// más habituales (español/catalán/inglés). Devuelve filas normalizadas:
//   { date, amount, type, category, description, payment, driver, plate }
// Conserva la FECHA original (clave para comparar meses/años).
// ============================================================
import ExcelJS from 'exceljs';

const strip = (s) => (s ?? '')
  .toString()
  .toLowerCase()
  .normalize('NFD')
  .replace(/[̀-ͯ]/g, '')
  .trim();

// Sinónimos de cabecera -> campo interno.
const HEADER_MAP = [
  ['date', ['fecha', 'dia', 'date', 'data', 'fecha hora', 'fecha y hora', 'dia/hora']],
  ['amount', ['importe', 'cantidad', 'monto', 'total', 'amount', 'euros', 'import', 'preu', 'precio', 'importe euros', 'importe (€)']],
  ['type', ['tipo', 'type', 'tipus', 'movimiento', 'i/g']],
  ['income', ['ingreso', 'ingresos', 'ingres', 'ingressos', 'cobrado', 'cobros', 'income']],
  ['expense', ['gasto', 'gastos', 'despesa', 'despeses', 'gastado', 'expense', 'pagos']],
  ['category', ['categoria', 'concepto', 'concepte', 'category', 'concept']],
  ['description', ['descripcion', 'detalle', 'detalle', 'notas', 'observaciones', 'description', 'descripcio', 'detall']],
  ['payment', ['pago', 'metodo', 'metodo de pago', 'forma de pago', 'payment', 'pagament', 'metode', 'forma pago']],
  ['driver', ['conductor', 'chofer', 'driver', 'empleado', 'xofer']],
  ['plate', ['matricula', 'coche', 'vehiculo', 'plate', 'vehicle', 'matricula coche']],
];

function fieldForHeader(h) {
  const n = strip(h);
  if (!n) return null;
  for (const [field, syns] of HEADER_MAP) {
    if (syns.some((s) => n === s || n.includes(s))) return field;
  }
  return null;
}

// Importe: "1.234,56", "12,50", "12.50", "€", espacios, negativos.
function parseAmount(v) {
  if (v == null) return null;
  if (typeof v === 'number') return v;
  let s = String(v).replace(/[^\d.,-]/g, '').trim();
  if (!s) return null;
  const hasDot = s.includes('.');
  const hasComma = s.includes(',');
  if (hasDot && hasComma) {
    s = s.lastIndexOf(',') > s.lastIndexOf('.')
      ? s.replace(/\./g, '').replace(',', '.')
      : s.replace(/,/g, '');
  } else if (hasComma) {
    s = s.replace(',', '.');
  }
  const n = parseFloat(s);
  return Number.isFinite(n) ? n : null;
}

// Fecha: Date de Excel, o texto dd/mm/aaaa, aaaa-mm-dd, dd-mm-aa…
function parseDate(v) {
  if (v == null || v === '') return null;
  if (v instanceof Date && !Number.isNaN(v.getTime())) return v;
  const s = String(v).trim();
  // ISO aaaa-mm-dd
  let m = s.match(/^(\d{4})[-/](\d{1,2})[-/](\d{1,2})/);
  if (m) return new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
  // dd/mm/aaaa o dd-mm-aa
  m = s.match(/^(\d{1,2})[-/](\d{1,2})[-/](\d{2,4})/);
  if (m) {
    let y = +m[3];
    if (y < 100) y += 2000;
    return new Date(Date.UTC(y, +m[2] - 1, +m[1]));
  }
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? null : d;
}

function inferType(row, defaultType) {
  // 1) columna 'tipo' explícita
  const t = strip(row.type);
  if (t) {
    if (/ingres|income|cobr|carrera|cursa|venta/.test(t)) return 'income';
    if (/gast|despesa|expense|pago|compra/.test(t)) return 'expense';
  }
  // 2) columnas separadas ingresos / gastos
  const inc = parseAmount(row.income);
  const exp = parseAmount(row.expense);
  if (inc && inc !== 0) return 'income';
  if (exp && exp !== 0) return 'expense';
  // 3) por defecto elegido en la app (auto = por el signo del importe)
  if (defaultType === 'income' || defaultType === 'expense') return defaultType;
  const amt = parseAmount(row.amount);
  if (amt != null && amt < 0) return 'expense';
  return 'income';
}

function amountOfRow(row) {
  // Si hay columnas separadas, usa la que tenga valor.
  const inc = parseAmount(row.income);
  const exp = parseAmount(row.expense);
  if (inc && inc !== 0) return Math.abs(inc);
  if (exp && exp !== 0) return Math.abs(exp);
  const a = parseAmount(row.amount);
  return a == null ? null : Math.abs(a);
}

// Devuelve filas normalizadas a partir de la matriz de celdas.
function rowsFromMatrix(matrix, defaultType) {
  // Busca la fila de cabecera: la primera con >=2 columnas reconocidas.
  let headerIdx = -1;
  let colMap = {};
  for (let i = 0; i < Math.min(matrix.length, 10); i++) {
    const map = {};
    matrix[i].forEach((cell, c) => {
      const f = fieldForHeader(cell);
      if (f && map[f] === undefined) map[f] = c;
    });
    if (Object.keys(map).length >= 2 && (map.amount !== undefined || map.income !== undefined || map.expense !== undefined)) {
      headerIdx = i;
      colMap = map;
      break;
    }
  }
  if (headerIdx === -1) {
    return { rows: [], headers: [], skipped: 0, error: 'no_headers' };
  }
  const get = (arr, field) => (colMap[field] === undefined ? null : arr[colMap[field]]);

  const rows = [];
  let skipped = 0;
  for (let i = headerIdx + 1; i < matrix.length; i++) {
    const arr = matrix[i];
    if (!arr || arr.every((c) => c == null || String(c).trim() === '')) continue;
    const raw = {
      date: get(arr, 'date'),
      amount: get(arr, 'amount'),
      income: get(arr, 'income'),
      expense: get(arr, 'expense'),
      type: get(arr, 'type'),
      category: get(arr, 'category'),
      description: get(arr, 'description'),
      payment: get(arr, 'payment'),
      driver: get(arr, 'driver'),
      plate: get(arr, 'plate'),
    };
    const amount = amountOfRow(raw);
    if (amount == null || amount === 0) { skipped++; continue; }
    rows.push({
      date: parseDate(raw.date),
      amount,
      type: inferType(raw, defaultType),
      category: raw.category ? String(raw.category).trim() : null,
      description: raw.description ? String(raw.description).trim() : null,
      payment: raw.payment ? String(raw.payment).trim() : null,
      driver: raw.driver ? String(raw.driver).trim() : null,
      plate: raw.plate ? String(raw.plate).trim() : null,
    });
  }
  const headers = Object.keys(colMap);
  return { rows, headers, skipped };
}

export async function parseImportFile(buffer, filename, { defaultType } = {}) {
  const isCsv = /\.csv$/i.test(filename || '');
  let matrix = [];
  if (isCsv) {
    const text = buffer.toString('utf8');
    const sep = text.includes(';') && !text.split('\n')[0].includes(',') ? ';' : (text.includes(';') ? ';' : ',');
    matrix = text.split(/\r?\n/).map((line) => line.split(sep).map((c) => c.replace(/^"|"$/g, '').trim()));
  } else {
    const wb = new ExcelJS.Workbook();
    await wb.xlsx.load(buffer);
    const ws = wb.worksheets[0];
    if (!ws) return { rows: [], headers: [], skipped: 0, error: 'empty' };
    ws.eachRow((row) => {
      const arr = [];
      row.eachCell({ includeEmpty: true }, (cell) => {
        let v = cell.value;
        if (v && typeof v === 'object') {
          if (v instanceof Date) { /* keep */ }
          else if (v.text !== undefined) v = v.text;        // rich text / hyperlink
          else if (v.result !== undefined) v = v.result;    // fórmula
          else v = v.toString();
        }
        arr.push(v);
      });
      matrix.push(arr);
    });
  }
  return rowsFromMatrix(matrix, defaultType);
}
