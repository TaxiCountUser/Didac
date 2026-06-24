// ============================================================
// TaxiCount - Parser semántico de transacciones por voz (Fase 2)
//
// Determinista (regex + lógica), SIN llamadas a IA, para controlar
// coste y latencia. Extrae de una frase en español:
//   amount, category, type, payment_method
// y, para las CARRERAS (ingresos), también:
//   origin, destination, odometer_km, client_name
// y devuelve missing_fields con lo que no pudo determinar.
//
// Es "best-effort": lo que no se pueda inferir se deja en null y el
// conductor lo confirma/corrige en el formulario antes de guardar.
// ============================================================

// Números compuestos catalanes "desena-i-unitat" (vint-i-cinc) o sin "i"
// (trenta-dos). Se expanden a dígitos ANTES de partir guiones, para no generar
// un "un"/"u" suelto (colisionaría con el artículo). 21->"21", 32->"32"...
const CAT_TENS = {
  vint: 20, trenta: 30, quaranta: 40, cinquanta: 50,
  seixanta: 60, setanta: 70, vuitanta: 80, noranta: 90,
};
const CAT_UNIT1 = {
  u: 1, un: 1, una: 1, dos: 2, dues: 2, tres: 3, quatre: 4,
  cinc: 5, sis: 6, set: 7, vuit: 8, nou: 9,
};
function expandCatalanTens(s) {
  return s.replace(
    /\b(vint|trenta|quaranta|cinquanta|seixanta|setanta|vuitanta|noranta)(?:[\s-]i)?[\s-](u|un|una|dos|dues|tres|quatre|cinc|sis|set|vuit|nou)\b/g,
    (_, t, u) => String(CAT_TENS[t] + CAT_UNIT1[u]),
  );
}

function normalize(s) {
  let out = (s || '')
    .toLowerCase()
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '') // quita acentos
    .replace(/[€$]/g, ' ');
  out = expandCatalanTens(out); // vint-i-cinc -> 25
  return out
    .replace(/-/g, ' ') // dos-cents -> dos cents
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
  // --- Catalán (unitats, desenes i tot menys 'un/una' per evitar l'article) ---
  dues: 2, quatre: 4, cinc: 5, sis: 6, set: 7, vuit: 8, nou: 9, deu: 10,
  onze: 11, dotze: 12, tretze: 13, catorze: 14, quinze: 15, setze: 16,
  disset: 17, desset: 17, divuit: 18, devuit: 18, dinou: 19, denou: 19,
  vint: 20, trenta: 30, quaranta: 40, cinquanta: 50, seixanta: 60,
  setanta: 70, vuitanta: 80, noranta: 90,
};
const HUNDREDS = {
  cien: 100, ciento: 100, doscientos: 200, doscientas: 200, trescientos: 300,
  trescientas: 300, cuatrocientos: 400, cuatrocientas: 400, quinientos: 500,
  quinientas: 500, seiscientos: 600, seiscientas: 600, setecientos: 700,
  setecientas: 700, ochocientos: 800, ochocientas: 800, novecientos: 900,
  novecientas: 900,
  cent: 100, // catalán; els compostos (dos-cents) es resolen amb l'escala 'cents'
};

const isDigitTok = (t) => /^\d+(?:[.,]\d+)*$/.test(t);
// Escala "cents"/"centes" (catalán): dos-cents -> dues centes -> ×100.
const isCentScale = (t) => t === 'cents' || t === 'centes';

// Interpreta separadores de miles/decimales en formato español (1.234,56) o
// inglés (1,234.56). Ej.: "292.000" -> 292000, "18,50" -> 18.5, "18.50" -> 18.5.
function regroup(s, sep) {
  const parts = s.split(sep);
  if (parts.length > 2) return parts.join(''); // varios separadores -> miles
  // Un separador: 3 dígitos a la derecha -> miles (292.000); 1-2 -> decimal (18,50).
  return parts[1].length === 3 ? parts[0] + parts[1] : `${parts[0]}.${parts[1]}`;
}
function parseGroupedNumber(str) {
  let s = String(str);
  const hasDot = s.includes('.');
  const hasComma = s.includes(',');
  if (hasDot && hasComma) {
    // El separador más a la derecha es el decimal.
    s = s.lastIndexOf(',') > s.lastIndexOf('.')
      ? s.replace(/\./g, '').replace(',', '.') // 1.234,56 (español)
      : s.replace(/,/g, ''); // 1,234.56 (inglés)
  } else if (hasDot) {
    s = regroup(s, '.');
  } else if (hasComma) {
    s = regroup(s, ',');
  }
  const v = parseFloat(s);
  return Number.isFinite(v) ? v : null;
}
const isNumTok = (t) =>
  isDigitTok(t) || t === 'mil' || isCentScale(t) || HUNDREDS[t] != null || UNITS[t] != null;

// Unidades de kilometraje (tras normalize() los acentos ya no están).
const KM_UNITS = new Set([
  'km', 'kms', 'kilometro', 'kilometros', 'kilometraje',
  'quilometre', 'quilometres', 'quilometratge', // catalán
]);
const isKmUnit = (t) => t != null && KM_UNITS.has(t);

function parseWords(tokens) {
  let total = 0;
  let current = 0;
  let found = false;
  for (const t of tokens) {
    if (t === 'y' || t === 'i') continue; // conectores es/ca
    if (t === 'mil') {
      current = current === 0 ? 1000 : current * 1000;
      total += current;
      current = 0;
      found = true;
    } else if (isCentScale(t)) {
      current = (current === 0 ? 1 : current) * 100; // dues centes -> 200
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
  if (digit) return parseGroupedNumber(digit);
  return parseWords(run);
}

function extractAmount(tokens) {
  let i = 0;
  while (i < tokens.length) {
    while (i < tokens.length && !isNumTok(tokens[i])) i++;
    if (i === tokens.length) return null;

    // Parte entera: run contiguo de números (y conector 'y')
    const run = [];
    let j = i;
    while (j < tokens.length && (isNumTok(tokens[j]) || tokens[j] === 'y')) {
      run.push(tokens[j]);
      j++;
    }

    // Si este número es un kilometraje (va seguido de km/kilómetros), no es
    // el importe: lo saltamos y seguimos buscando.
    if (isKmUnit(tokens[j])) {
      i = j + 1;
      continue;
    }

    const value0 = valueOfRun(run);
    if (value0 == null) {
      i = j;
      continue;
    }
    let value = value0;

    // Decimal con "con"/"amb"/"coma" (es/ca) SOLO si lo que sigue es otro número
    // (céntimos) y esos céntimos no son a su vez un kilometraje.
    const isDecimalConn = tokens[j] === 'con' || tokens[j] === 'amb' || tokens[j] === 'coma';
    if (isDecimalConn && j + 1 < tokens.length && isNumTok(tokens[j + 1])) {
      const run2 = [];
      let k = j + 1;
      while (k < tokens.length && (isNumTok(tokens[k]) || tokens[k] === 'y')) {
        run2.push(tokens[k]);
        k++;
      }
      if (!isKmUnit(tokens[k])) {
        const cents = valueOfRun(run2);
        if (cents != null) value += cents / 100;
      }
    }
    return Math.round(value * 100) / 100;
  }
  return null;
}

// Kilometraje del coche: número inmediatamente anterior a "km"/"kilómetros".
function extractKm(tokens) {
  for (let i = 0; i < tokens.length; i++) {
    if (!isKmUnit(tokens[i])) continue;
    const run = [];
    let k = i - 1;
    while (k >= 0 && (isNumTok(tokens[k]) || tokens[k] === 'y')) {
      run.unshift(tokens[k]);
      k--;
    }
    const v = valueOfRun(run);
    if (v != null) return Math.round(v);
  }
  return null;
}

function normToken(w) {
  return (w || '')
    .toLowerCase()
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/[.,;:!?]+$/g, '')
    .trim();
}

// Palabras que cierran el destino: importes, conectores, formas de pago, etc.
const ROUTE_STOP = new Set([
  'por', 'con', 'euros', 'euro', 'de', 'del', 'para', 'que', 'me', 'son',
  'pague', 'pagado', 'pago', 'cobre', 'cobrado', 'cobrada', 'cobro', 'ingreso',
  'tarjeta', 'efectivo', 'bizum', 'transferencia', 'metalico', 'contado',
  'marcando', 'marca', 'kilometros', 'km',
  // catalán
  'amb', 'per', 'fins', 'targeta', 'efectiu', 'tpv', 'cobrat', 'cobrament',
  'quilometres', 'monedes', 'bitllets',
]);
const isRouteStop = (t) => t === '' || isNumTok(t) || isKmUnit(t) || ROUTE_STOP.has(t);

function cleanPlace(s) {
  const out = (s || '').replace(/\s+/g, ' ').replace(/[.,;:!?]+$/g, '').trim();
  if (!out) return null;
  return out.charAt(0).toUpperCase() + out.slice(1);
}

// Origen/destino con patrón "de X a Y" o "desde X hasta/a Y".
// Trabaja sobre el texto original para conservar los nombres de lugar.
const ROUTE_RE = /\b(?:des\s+de|desde|de)\s+(.+?)\s+(?:fins\s+a|fins|hasta|a)\s+(.+)$/i;
function extractRoute(text) {
  const m = (text || '').match(ROUTE_RE);
  if (!m) return { origin: null, destination: null };
  const origin = cleanPlace(m[1]);
  const destWords = [];
  for (const w of m[2].split(/\s+/)) {
    // normalize() expande números catalanes (vint-i-cinc -> 25) y parte guiones,
    // así el destino se corta también ante un número dicho en catalán.
    const stopTok = normalize(w).split(' ')[0];
    if (isRouteStop(stopTok)) break;
    destWords.push(w);
  }
  const destination = cleanPlace(destWords.join(' '));
  if (!origin || !destination) return { origin: null, destination: null };
  return { origin, destination };
}

// Empresas/clientes conocidos. Ampliable; si no se detecta ninguna, la
// carrera se considera de cliente particular (client_name = null).
// El más específico va primero (p. ej. "mutua asepeyo" antes que "asepeyo").
const KNOWN_COMPANIES = [
  ['mutua asepeyo', 'Mutua Asepeyo'],
  ['asepeyo', 'Asepeyo'],
  ['movitaxi', 'Movitaxi'],
  ['gitaxi', 'Gitaxi'],
  ['onecab', 'OneCab'],
  ['radio taxi', 'Radio Taxi'],
  ['radiotaxi', 'Radio Taxi'],
  ['cooperativa', 'Cooperativa'],
];
function findClient(norm) {
  for (const [needle, label] of KNOWN_COMPANIES) {
    if (norm.includes(needle)) return label;
  }
  return null;
}

// --- Diccionarios de palabras clave ---
const CATEGORY_KEYWORDS = {
  gasolina: ['gasolina', 'benzina'],
  gasoil: ['gasoil', 'gasoleo', 'diesel', 'gasoil'],
  taller: ['taller', 'mecanico', 'reparacion', 'revision', 'averia', 'reparacio', 'avaria'],
  peaje: ['peaje', 'autopista'],
  parking: ['parking', 'aparcamiento', 'aparcar', 'estacionamiento', 'garaje', 'aparcament'],
  lavado: ['lavado', 'lavar', 'lavadero', 'lavacoches', 'rentat', 'rentar'],
  multa: ['multa', 'sancion', 'sancio'],
  seguro: ['seguro', 'assegurança', 'asseguranca'],
  comida: ['comida', 'dieta', 'dietas', 'menu', 'menjar'],
  compra: ['compra', 'comprado', 'comprar', 'material', 'recambio', 'recambios', 'pieza', 'piezas', 'comprat', 'recanvi', 'recanvis'],
};

const INCOME_WORDS = [
  'cobrado', 'cobrada', 'cobre', 'cobrar', 'cobro', 'ingreso', 'ingresos',
  'ingresado', 'ingresar', 'ganado', 'recaudado', 'recaudacion', 'facturado',
  'facturacion', 'carrera', 'carreras',
  // catalán
  'cobrat', 'cobrada', 'cobrament', 'ingressat', 'ingres', 'ingressos',
  'cursa', 'curses', 'facturat', 'servei', 'serveis', 'viatge', 'viatges',
  'recorregut', 'recorreguts', 'trajecte', 'trajectes',
];
const EXPENSE_WORDS = [
  'pagado', 'pagada', 'pago', 'pague', 'paga', 'gasto', 'gastado', 'gaste',
  'gastar', 'comprado', 'compra', 'comprar',
  // catalán
  'pagat', 'pagament', 'despesa', 'despeses', 'gastat', 'comprat',
];

const PAYMENT_KEYWORDS = {
  tarjeta: ['tarjeta', 'visa', 'credito', 'debito', 'targeta', 'tpv', 'datafono', 'datafon'],
  efectivo: [
    'efectivo', 'metalico', 'contado', 'cash', 'efectiu', 'metallic',
    'monedas', 'moneda', 'monedes', 'billetes', 'billete', 'bitllets', 'bitllet',
  ],
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
  const odometer_km = extractKm(tokens);
  const client_name = findClient(norm);

  // Categoría de GASTO por palabra clave (gasolina, taller, peaje…).
  let category = findCategory(tokens);

  // La ruta solo tiene sentido en carreras (ingresos): si la frase es un gasto
  // con categoría, ignoramos cualquier "de X a Y" para no inventar origen/destino.
  let { origin, destination } = category
    ? { origin: null, destination: null }
    : extractRoute(text);

  // Parece una carrera si hay ruta o cliente identificado.
  const looksLikeTrip = (!!origin && !!destination) || client_name != null;

  // Tipo: ingreso si hay palabra de ingreso o si parece una carrera (y no es un
  // gasto con categoría); si no, gasto por defecto.
  let type;
  if (has(INCOME_WORDS)) type = 'income';
  else if (looksLikeTrip && !category) type = 'income';
  else type = 'expense';

  // Categoría por defecto para ingresos "simples" (sin ruta ni cliente).
  if (!category && type === 'income' && !looksLikeTrip) category = 'ingreso_tarjeta';

  const payment_method = findPayment(tokens);

  const missing_fields = [];
  if (amount == null) missing_fields.push('amount');
  if (type === 'expense' && !category) missing_fields.push('category');
  if (!payment_method) missing_fields.push('payment_method');

  return {
    amount: amount == null ? null : amount,
    category: category || null,
    type,
    payment_method: payment_method || null,
    origin: origin || null,
    destination: destination || null,
    odometer_km: odometer_km == null ? null : odometer_km,
    client_name: client_name || null,
    missing_fields,
  };
}

export default parseTransactionText;
