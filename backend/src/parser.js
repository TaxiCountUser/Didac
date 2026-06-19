// ============================================================
// TaxiCount - Parser semántico de transacciones por voz (Fase 2)
//
// Determinista (regex + lógica), SIN llamadas a IA, para controlar
// coste y latencia. Extrae de una frase en español:
//   amount, category, type, payment_method
// y devuelve missing_fields con lo que no pudo determinar.
// ============================================================

function normalize(s) {
  return (s || '')
    .toLowerCase()
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '') // quita acentos
    .replace(/[€$]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

// --- Números en palabras (español) ---
// OJO: 'un'/'uno'/'una' se omiten a propósito (colisionan con el artículo,
// p.ej. "un gasto de 90"). Los compuestos (veintiuno...) sí están.
const UNITS = {
  cero: 0, dos: 2, tres: 3, cuatro: 4, cinco: 5, seis: 6, siete: 7, ocho: 8,
  nueve: 9, diez: 10, once: 11, doce: 12, trece: 13, catorce: 14, quince: 15,
  dieciseis: 16, diecisiete: 17, dieciocho: 18, diecinueve: 19, veinte: 20,
  veintiuno: 21, veintiun: 21, veintidos: 22, veintitres: 23, veinticuatro: 24,
  veinticinco: 25, veintiseis: 26, veintisiete: 27, veintiocho: 28, veintinueve: 29,
  treinta: 30, cuarenta: 40, cincuenta: 50, sesenta: 60, setenta: 70,
  ochenta: 80, noventa: 90,
};
const HUNDREDS = {
  cien: 100, ciento: 100, doscientos: 200, doscientas: 200, trescientos: 300,
  trescientas: 300, cuatrocientos: 400, cuatrocientas: 400, quinientos: 500,
  quinientas: 500, seiscientos: 600, seiscientas: 600, setecientos: 700,
  setecientas: 700, ochocientos: 800, ochocientas: 800, novecientos: 900,
  novecientas: 900,
};

const isDigitTok = (t) => /^\d+(?:[.,]\d+)?$/.test(t);
const isNumTok = (t) =>
  isDigitTok(t) || t === 'mil' || HUNDREDS[t] != null || UNITS[t] != null;

function parseWords(tokens) {
  let total = 0;
  let current = 0;
  let found = false;
  for (const t of tokens) {
    if (t === 'y') continue;
    if (t === 'mil') {
      current = current === 0 ? 1000 : current * 1000;
      total += current;
      current = 0;
      found = true;
    } else if (HUNDREDS[t] != null) {
      current += HUNDREDS[t];
      found = true;
    } else if (UNITS[t] != null) {
      current += UNITS[t];
      found = true;
    }
  }
  return found ? total + current : null;
}

function valueOfRun(run) {
  const digit = run.find(isDigitTok);
  if (digit) return parseFloat(digit.replace(',', '.'));
  return parseWords(run);
}

function extractAmount(tokens) {
  let i = 0;
  while (i < tokens.length && !isNumTok(tokens[i])) i++;
  if (i === tokens.length) return null;

  // Parte entera: run contiguo de números (y conector 'y')
  const run = [];
  let j = i;
  while (j < tokens.length && (isNumTok(tokens[j]) || tokens[j] === 'y')) {
    run.push(tokens[j]);
    j++;
  }
  let value = valueOfRun(run);
  if (value == null) return null;

  // Decimal con "con" SOLO si lo que sigue a 'con' es otro número (céntimos)
  if (tokens[j] === 'con' && j + 1 < tokens.length && isNumTok(tokens[j + 1])) {
    const run2 = [];
    let k = j + 1;
    while (k < tokens.length && (isNumTok(tokens[k]) || tokens[k] === 'y')) {
      run2.push(tokens[k]);
      k++;
    }
    const cents = valueOfRun(run2);
    if (cents != null) value += cents / 100;
  }
  return Math.round(value * 100) / 100;
}

// --- Diccionarios de palabras clave ---
const CATEGORY_KEYWORDS = {
  gasolina: ['gasolina'],
  gasoil: ['gasoil', 'gasoleo', 'diesel'],
  taller: ['taller', 'mecanico', 'reparacion', 'revision', 'averia'],
  peaje: ['peaje', 'autopista'],
  parking: ['parking', 'aparcamiento', 'aparcar', 'estacionamiento', 'garaje'],
  lavado: ['lavado', 'lavar', 'lavadero', 'lavacoches'],
  multa: ['multa', 'sancion'],
  seguro: ['seguro'],
  comida: ['comida', 'dieta', 'dietas', 'menu'],
  compra: ['compra', 'comprado', 'comprar', 'material', 'recambio', 'recambios', 'pieza', 'piezas'],
};

const INCOME_WORDS = [
  'cobrado', 'cobrada', 'cobre', 'cobrar', 'cobro', 'ingreso', 'ingresos',
  'ingresado', 'ingresar', 'ganado', 'recaudado', 'recaudacion', 'facturado',
  'facturacion', 'carrera', 'carreras',
];
const EXPENSE_WORDS = [
  'pagado', 'pagada', 'pago', 'pague', 'paga', 'gasto', 'gastado', 'gaste',
  'gastar', 'comprado', 'compra', 'comprar',
];

const PAYMENT_KEYWORDS = {
  tarjeta: ['tarjeta', 'visa', 'credito', 'debito'],
  efectivo: ['efectivo', 'metalico', 'contado', 'cash'],
  bizum: ['bizum'],
  transferencia: ['transferencia', 'transfer'],
};

function findCategory(words) {
  for (const [cat, kws] of Object.entries(CATEGORY_KEYWORDS)) {
    if (kws.some((k) => words.includes(k))) return cat;
  }
  return null;
}

function findPayment(words) {
  for (const [pm, kws] of Object.entries(PAYMENT_KEYWORDS)) {
    if (kws.some((k) => words.includes(k))) return pm;
  }
  return null;
}

export function parseTransactionText(text) {
  const norm = normalize(text);
  const tokens = norm.split(' ').filter(Boolean);
  const words = new Set(tokens);
  const has = (list) => list.some((w) => words.has(w));

  const amount = extractAmount(tokens);

  // Tipo: ingreso si hay palabra de ingreso; si no, gasto por defecto.
  const type = has(INCOME_WORDS) ? 'income' : 'expense';

  // Categoría: por palabra clave; si es ingreso sin categoría -> ingreso_tarjeta.
  let category = findCategory(tokens);
  if (!category && type === 'income') category = 'ingreso_tarjeta';

  const payment_method = findPayment(tokens);

  const missing_fields = [];
  if (amount == null) missing_fields.push('amount');
  if (!category) missing_fields.push('category');
  if (!payment_method) missing_fields.push('payment_method');

  return {
    amount: amount == null ? null : amount,
    category: category || null,
    type,
    payment_method: payment_method || null,
    missing_fields,
  };
}

export default parseTransactionText;
