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
  'por', 'con', 'en', 'euros', 'euro', 'de', 'del', 'para', 'que', 'me', 'son',
  'pague', 'pagado', 'pago', 'cobre', 'cobrado', 'cobrada', 'cobro', 'ingreso',
  'tarjeta', 'efectivo', 'bizum', 'transferencia', 'metalico', 'contado',
  'marcando', 'marca', 'kilometros', 'km',
  // catalán
  'amb', 'per', 'fins', 'pagat', 'pagada', 'targeta', 'efectiu', 'tpv', 'cobrat', 'cobrament',
  'quilometres', 'monedes', 'bitllets',
]);
const isRouteStop = (t) => t === '' || isNumTok(t) || isKmUnit(t) || ROUTE_STOP.has(t);

function cleanPlace(s) {
  const out = (s || '').replace(/\s+/g, ' ').replace(/[.,;:!?]+$/g, '').trim();
  if (!out) return null;
  return out.charAt(0).toUpperCase() + out.slice(1);
}

// Corta un lugar en la primera palabra de parada (importe, conector, forma de
// pago…). normalize() expande números catalanes (vint-i-cinc -> 25) y parte
// guiones, así el lugar se corta también ante un número dicho en catalán.
function cutPlace(s) {
  const words = [];
  for (const w of (s || '').split(/\s+/)) {
    const stopTok = normalize(w).split(' ')[0];
    if (isRouteStop(stopTok) || fuzzyPayment(stopTok)) break;
    words.push(w);
  }
  return cleanPlace(words.join(' '));
}

// Origen del patrón "de X a Y": si lleva delante un importe ("carrera de 50
// euros de Figueres a Girona"), se queda solo con lo que va tras el importe.
function trimOrigin(s) {
  const words = (s || '').split(/\s+/);
  let last = -1;
  words.forEach((w, i) => {
    const t = normalize(w).split(' ')[0];
    if (isNumTok(t) || isKmUnit(t) || t === 'euros' || t === 'euro') last = i;
  });
  if (last === -1) return cleanPlace(s);
  const rest = words.slice(last + 1).join(' ')
    .replace(/^(?:des\s+de|desde|de\s+la|de\s+l['’]|del|de)\s+/i, '');
  return cleanPlace(rest);
}

// Origen/destino con patrón "de X a Y" o "desde X hasta/a/cap a Y". También admite
// contracciones y artículos: del/de la/de l' como inicio y al/a la/a l' como
// conector ("de Sants al Museu Dalí"). Trabaja sobre el texto original para
// conservar los nombres de lugar.
const ROUTE_RE = /\b(?:des\s+de|desde|de\s+la|de\s+l['’]|del|de)\s+(.+?)\s+(?:cap\s+a|fins\s+a|fins|hasta|hacia|direcci[oó]n?|a\s+la|a\s+l['’]|al|a)\s+(.+)$/i;
// Orden invertido: "a Girona des de Figueres", "cap a Girona desde Figueres".
const ROUTE_REV_RE = /(?:^|\s)(?:cap\s+a|fins\s+a|hacia|hasta|a\s+la|a\s+l['’]|al|a)\s+(.+?)\s+(?:des\s+de\s+la|des\s+de\s+l['’]|des\s+del|des\s+de|desde\s+la|desde\s+el|desde)\s+(.+)$/i;

function routeReversed(text) {
  const m = (text || '').match(ROUTE_REV_RE);
  if (!m) return null;
  // Si el tramo del destino arrastra otro "a" ("porta a la senyora a Girona"),
  // el destino es lo que va tras el último conector.
  const dest = m[1].split(/\s+(?:cap\s+a|a\s+la|a\s+l['’]|al|a)\s+/i).pop();
  const origin = cutPlace(m[2]);
  const destination = cutPlace(dest);
  return origin && destination ? { origin, destination } : null;
}

function routeByRegex(text) {
  const m = (text || '').match(ROUTE_RE);
  if (!m) return null;
  const origin = trimOrigin(m[1]);
  const destination = cutPlace(m[2]);
  return origin && destination ? { origin, destination } : null;
}

// --- Rutas SIN "de X a Y": "Figueres Girona", "Figueres cap a Girona",
// "Figueres - Girona". Se trabaja por tokens: una "palabra de lugar" es la que
// no es número, conector, forma de pago, palabra de ingreso/gasto, categoría,
// empresa conocida ni muletilla del dictado.
const ROUTE_FILLER = [
  'carrera', 'carreras', 'cursa', 'curses', 'servei', 'serveis', 'servicio', 'servicios',
  'viatge', 'viatges', 'viaje', 'viajes', 'trajecte', 'trayecto', 'anada', 'tornada',
  'ida', 'vuelta', 'apunta', 'apuntar', 'anota', 'anotar', 'posa', 'pon', 'registra',
  'he', 'ha', 'hem', 'fet', 'fer', 'hecho', 'hacer', 'vaig', 'fui', 'portat', 'porta',
  'llevado', 'dut', 'deixat', 'dejado', 'un', 'una', 'uno', 'el', 'la', 'els', 'les',
  'los', 'las', 'lo', 'del', 'de', 'des', 'desde', 'al', 'a', 'i', 'y', 'e', 'o', 'u',
  'taxi', 'client', 'cliente', 'clienta', 'clients', 'senyor', 'senyora', 'senor', 'senora',
  'persona', 'persones', 'personas', 'avui', 'hoy', 'ahir', 'ayer', 'dema', 'manana',
  'mati', 'tarda', 'tarde', 'nit', 'noche', 'ara', 'ahora', 'total', 'import', 'importe',
  'preu', 'precio', 'fa', 'fan', 'val', 'vale', 'pagat', 'pagada', 'pagament', 'empresa',
  'mutua', 'tarifa', 'suplement', 'suplemento', 'propina', 'hores', 'horas', 'hora',
  'minuts', 'minutos', 'cap', 'hacia', 'hasta', 'fins', 'direccio', 'direccion',
  'dilluns', 'dimarts', 'dimecres', 'dijous', 'divendres', 'dissabte', 'diumenge',
  'lunes', 'martes', 'miercoles', 'jueves', 'viernes', 'sabado', 'domingo',
];
let _placeBlock = null;
function placeBlock() {
  if (_placeBlock) return _placeBlock;
  _placeBlock = new Set([
    ...ROUTE_STOP, ...ROUTE_FILLER, ...INCOME_WORDS, ...EXPENSE_WORDS,
    ...Object.values(PAYMENT_KEYWORDS).flat(), ...Object.values(CATEGORY_KEYWORDS).flat(),
    ...KNOWN_COMPANIES.flatMap(([needle]) => needle.split(' ')),
    ...Object.keys(MONTHS_WHEN),
  ]);
  return _placeBlock;
}

// Tokens del texto original conservando la forma dicha (para devolver "Llançà"
// y no "llanca"). "Figueres-Girona" (dos nombres en mayúscula con guion) se
// parte en [Figueres, -, Girona]; un guion suelto es separador de ruta.
function rawTokens(text) {
  const out = [];
  for (const w of (text || '').split(/\s+/)) {
    if (!w) continue;
    if (/^[-–—]+$/.test(w)) { out.push({ raw: '-', n: '-' }); continue; }
    const clean = w.replace(/^[¿¡"'(]+|[.,;:!?€$")]+$/g, '');
    if (!clean) continue;
    const parts = /^\p{Lu}[\p{L}'’·]+[-–]\p{Lu}[\p{L}'’·]+$/u.test(clean) ? clean.split(/[-–]/) : [clean];
    parts.forEach((p, i) => {
      if (i > 0) out.push({ raw: '-', n: '-' });
      out.push({ raw: p, n: normToken(p) });
    });
  }
  return out;
}

const upper = (s) => /^\p{Lu}/u.test(s || '');

// Una palabra puede formar parte de un nombre de lugar.
function isPlaceWord(tok, blocked) {
  const n = (tok.n || '').replace(/^[ld]['’]/, '');
  if (n.length < 3 || /\d/.test(n) || n === '-') return false;
  if (isNumTok(n) || isKmUnit(n) || fuzzyPayment(n)) return false;
  return !placeBlock().has(n) && !blocked.has(n);
}

// Conectores de ruta hacia delante sin "de" inicial: devuelve cuántos tokens
// ocupa el conector en la posición i (0 = no hay).
function fwdConnector(toks, i) {
  const t = toks[i].n;
  const next = toks[i + 1]?.n;
  if ((t === 'cap' || t === 'fins') && next === 'a') return 2;
  if (t === 'hacia' || t === 'hasta' || t === 'fins' || t === '-') return 1;
  if (t === 'direccio' || t === 'direccion') return next === 'a' ? 2 : 1;
  return 0;
}

function joinRaw(toks) { return cleanPlace(toks.map((t) => t.raw).join(' ')); }

// Parte un tramo de palabras de lugar en origen+destino usando los lugares ya
// conocidos de la empresa (vocabulario). Primero ambos conocidos; si no, uno.
function splitByVocab(run, places) {
  if (!places.size) return null;
  const key = (a) => a.map((t) => t.n).join(' ');
  let oneKnown = null;
  for (let k = 1; k < run.length; k++) {
    const l = places.has(key(run.slice(0, k)));
    const r = places.has(key(run.slice(k)));
    if (l && r) return [run.slice(0, k), run.slice(k)];
    if ((l || r) && !oneKnown) oneKnown = [run.slice(0, k), run.slice(k)];
  }
  return oneKnown;
}

function routeByTokens(text, places, blocked) {
  const toks = rawTokens(text);
  const isP = (i) => i >= 0 && i < toks.length && isPlaceWord(toks[i], blocked);

  // 1) "X cap a Y" / "X hacia Y" / "X fins a Y" / "X - Y" / "X a Y" (este último
  //    solo si ambos lugares empiezan en mayúscula: "Figueres a Girona").
  for (let i = 1; i < toks.length - 1; i++) {
    let len = fwdConnector(toks, i);
    if (!len && (toks[i].n === 'a' || toks[i].n === 'al')
        && upper(toks[i - 1].raw) && upper(toks[i + 1]?.raw)) len = 1;
    if (!len || !isP(i - 1) || !isP(i + len)) continue;
    let s = i - 1;
    while (isP(s - 1)) s--;
    let e = i + len;
    while (isP(e + 1)) e++;
    return { origin: joinRaw(toks.slice(s, i)), destination: joinRaw(toks.slice(i + len, e + 1)) };
  }

  // 2) Dos lugares seguidos sin conector: "Figueres Girona 50 euros".
  for (let i = 0; i < toks.length; i++) {
    if (!isP(i)) continue;
    let e = i;
    while (isP(e + 1)) e++;
    const run = toks.slice(i, e + 1);
    const byVocab = splitByVocab(run, places);
    const split = byVocab || (run.length === 2 ? [[run[0]], [run[1]]] : null);
    // Sin conector ni lugar conocido es una SUPOSICIÓN ("Transports Puig" puede
    // ser una empresa): guess=true hace que needsLlm consulte al LLM.
    if (split) return { origin: joinRaw(split[0]), destination: joinRaw(split[1]), guess: !byVocab };
    i = e;
  }
  return null;
}

// vocab.places / vocab.clients: lugares y clientes ya usados por la empresa.
function extractRoute(text, vocab = {}) {
  const norm = (s) => normalize(s).split(' ').map(normToken).join(' ');
  const places = new Set((vocab.places || []).map(norm).filter(Boolean));
  const blocked = new Set((vocab.clients || []).flatMap((c) => norm(c).split(' ')));
  return routeReversed(text) || routeByRegex(text) || routeByTokens(text, places, blocked)
    || { origin: null, destination: null };
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

// Distancia de edición (Levenshtein) para tolerar errores de transcripción.
function levenshtein(a, b) {
  const m = a.length;
  const n = b.length;
  if (m === 0) return n;
  if (n === 0) return m;
  let prev = Array.from({ length: n + 1 }, (_, i) => i);
  for (let i = 1; i <= m; i++) {
    const cur = [i];
    for (let j = 1; j <= n; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      cur[j] = Math.min(cur[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost);
    }
    prev = cur;
  }
  return prev[n];
}

// Empresas conocidas de una sola palabra (para el match difuso por palabra).
const FUZZY_COMPANIES = KNOWN_COMPANIES.filter(([needle]) => !needle.includes(' ') && needle.length >= 5);

// Reconoce una empresa aunque la voz la transcriba parecido: "gitasi" -> Gitaxi.
// Conservador: solo palabras de longitud similar (±1) y distancia <= 1, para no
// confundir palabras comunes (p. ej. "taxi" no se convierte en "Gitaxi").
function fuzzyClient(tokens) {
  for (const w of tokens) {
    if (w.length < 5) continue;
    for (const [needle, label] of FUZZY_COMPANIES) {
      if (Math.abs(w.length - needle.length) > 1) continue;
      if (levenshtein(w, needle) <= 1) return label;
    }
  }
  return null;
}

// Clientes que la propia empresa ya ha usado (vocab.clients). Exacto por
// palabras completas y, si no, difuso (distancia <= 1 sobre el nombre entero,
// solo nombres de 5+ letras): "transport puig" -> "Transports Puig".
function vocabClient(norm, tokens, clients = []) {
  const list = clients
    .map((c) => [normalize(c).split(' ').map(normToken).join(' '), c])
    .filter(([n]) => n)
    .sort((a, b) => b[0].length - a[0].length);
  const padded = ` ${norm} `;
  for (const [n, label] of list) if (padded.includes(` ${n} `)) return label;
  for (const [n, label] of list) {
    if (n.length < 5) continue;
    const words = n.split(' ').length;
    for (let i = 0; i + words <= tokens.length; i++) {
      const win = tokens.slice(i, i + words).join(' ');
      if (Math.abs(win.length - n.length) <= 1 && levenshtein(win, n) <= 1) return label;
    }
  }
  return null;
}

// --- Diccionarios de palabras clave ---
const CATEGORY_KEYWORDS = {
  gasolina: ['gasolina', 'benzina'],
  gasoil: ['gasoil', 'gasoleo', 'diesel', 'gasoil'],
  carga_electrica: ['electrica', 'electric', 'electricitat', 'electricidad',
    'recarga', 'carga', 'carrega', 'cargador', 'enchufe', 'endoll', 'kwh'],
  autonomos: ['autonomos', 'autonomo', 'autonom', 'autonoms', 'tgss', 'cuota'],
  seguridad_social: ['seguridad', 'social', 'ss', 'cotizacion', 'cotitzacio',
    'nomina', 'nomines', 'salario', 'salaris', 'asalariado', 'assalariat'],
  taller: ['taller', 'mecanico', 'reparacion', 'revision', 'averia', 'reparacio', 'avaria'],
  peaje: ['peaje', 'autopista'],
  parking: ['parking', 'aparcamiento', 'aparcar', 'estacionamiento', 'garaje', 'aparcament', 'parquing', 'aparcat'],
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
// Gasto inequívoco. "Pagado/pagat" NO lo es: en una carrera "pagat amb bizum"
// es el CLIENTE quien paga (= ingreso).
const STRONG_EXPENSE_WORDS = [
  'gasto', 'gastos', 'gastado', 'gaste', 'gastar', 'comprado', 'compra', 'comprar',
  'despesa', 'despeses', 'gastat', 'comprat',
];
const PAY_VERBS = ['pagado', 'pagada', 'pago', 'pague', 'paga', 'pagat', 'pagament'];

const PAYMENT_KEYWORDS = {
  tarjeta: ['tarjeta', 'visa', 'debito', 'targeta', 'tpv', 'datafono', 'datafon',
    'mastercard', 'contactless', 'amex'],
  efectivo: [
    'efectivo', 'metalico', 'contado', 'cash', 'efectiu', 'metallic', 'metal·lic',
    'monedas', 'moneda', 'monedes', 'billetes', 'billete', 'bitllets', 'bitllet',
  ],
  bizum: ['bizum', 'bisum', 'visum', 'bizzum'],
  transferencia: ['transferencia', 'transfer'],
  // Crédito / facturas pendientes = el cliente queda a deber.
  credito: ['credito', 'fiado', 'fiar', 'pendiente', 'factura', 'facturas',
    'debe', 'deber', 'deure', 'deuda', 'fiat', 'credit', 'pendent', 'factures'],
};

function findCategory(words) {
  for (const [cat, kws] of Object.entries(CATEGORY_KEYWORDS)) {
    if (kws.some((k) => words.includes(k))) return cat;
  }
  return null;
}

// Forma de pago aunque la voz la corte o la deforme: "bizu" -> bizum,
// "targe" -> tarjeta, "efectivu" -> efectivo. Solo sobre las palabras largas e
// inequívocas (no las de crédito: "facturat" no debe convertirse en "factura").
const FUZZY_PAY = [
  ['bizum', 'bizum'], ['tarjeta', 'tarjeta'], ['targeta', 'tarjeta'], ['datafono', 'tarjeta'],
  ['efectivo', 'efectivo'], ['efectiu', 'efectivo'], ['metalico', 'efectivo'],
  ['transferencia', 'transferencia'],
];
function fuzzyPayment(t) {
  if (!t || t.length < 4) return null;
  for (const [kw, pm] of FUZZY_PAY) {
    if (t === kw) return pm;
    if (kw.startsWith(t) && kw.length - t.length <= 2) return pm;
    if (t.length >= 5 && Math.abs(t.length - kw.length) <= 1 && levenshtein(t, kw) <= 1) return pm;
  }
  return null;
}

function findPayment(words) {
  for (const [pm, kws] of Object.entries(PAYMENT_KEYWORDS)) {
    if (kws.some((k) => words.includes(k))) return pm;
  }
  for (const w of words) {
    const pm = fuzzyPayment(w);
    if (pm) return pm;
  }
  return null;
}

// --- Empresa/cliente dicho explícitamente: "empresa X" / "cliente X" ---
// Tras la palabra "empresa" (o "cliente"/"client") se toma el nombre que sigue,
// PERO con criterios de corte para no tragarse el resto de la frase:
//   - se detiene ante un número, kilometraje, conector de ruta (desde/hasta/a/
//     de), forma de pago o palabra de ingreso/gasto.
//   - máximo 4 palabras (los nombres de empresa no suelen ser más largos).
// Ej.: "10 € empresa ramon bilbao desde barcelona hasta madrid pagado con visa"
//      -> client_name = "Ramon Bilbao" (corta en "desde").
const COMPANY_TRIGGER = new Set(['empresa', 'cliente', 'client']);
const COMPANY_STOP = new Set([
  ...ROUTE_STOP, ...INCOME_WORDS, ...EXPENSE_WORDS,
  'desde', 'des', 'hasta', 'fins', 'a', 'empresa', 'cliente', 'client',
  'euros', 'euro',
  // "client habitual", "el client ha pagat": no son nombres de empresa.
  ...ROUTE_FILLER, 'habitual', 'particular', 'nou', 'nuevo', 'fix', 'fijo', 'privat', 'privado',
]);
function extractCompany(text) {
  const raw = (text || '').split(/\s+/).filter(Boolean);
  let idx = -1;
  for (let i = 0; i < raw.length; i++) {
    if (COMPANY_TRIGGER.has(normToken(raw[i]))) { idx = i; break; }
  }
  if (idx === -1) return null;

  const nameWords = [];
  for (let j = idx + 1; j < raw.length; j++) {
    const tok = normalize(raw[j]).split(' ')[0]; // expande nº catalanes, quita acentos
    if (!tok || isNumTok(tok) || isKmUnit(tok) || COMPANY_STOP.has(tok)) break;
    nameWords.push(raw[j].replace(/[.,;:!?]+$/g, ''));
    if (nameWords.length >= 4) break;
  }
  const name = nameWords.join(' ').replace(/\s+/g, ' ').trim();
  if (!name) return null;
  // Mayúscula inicial en cada palabra: "ramon bilbao" -> "Ramon Bilbao".
  return name.split(' ').map((w) => (w ? w.charAt(0).toUpperCase() + w.slice(1) : w)).join(' ');
}

// --- Fecha/hora dichas explícitamente (punto 2) ---
// Devuelve un ISO string si el audio menciona una fecha y/o una hora; si no,
// null (para que el frontend mantenga la fecha/hora actual del sistema).
const MONTHS_WHEN = {
  enero: 1, febrero: 2, marzo: 3, abril: 4, mayo: 5, junio: 6, julio: 7,
  agosto: 8, septiembre: 9, setiembre: 9, octubre: 10, noviembre: 11, diciembre: 12,
  gener: 1, febrer: 2, marc: 3, abril_ca: 4, maig: 5, juny: 6, juliol: 7,
  agost: 8, setembre: 9, octubre_ca: 10, novembre: 11, desembre: 12,
};
// Horas escritas con palabras (1-12) en es/ca, por si la voz no devuelve dígitos.
const WORD_HOURS = {
  una: 1, un: 1, dos: 2, dues: 2, tres: 3, cuatro: 4, quatre: 4, cinco: 5, cinc: 5,
  seis: 6, sis: 6, siete: 7, set: 7, ocho: 8, vuit: 8, huit: 8, nueve: 9, nou: 9,
  diez: 10, deu: 10, once: 11, onze: 11, doce: 12, dotze: 12,
};
function stripAccents(s) {
  return (s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
}
export function extractWhen(text, now = new Date()) {
  const t = stripAccents(text);
  let hasDate = false; let hasTime = false;
  const d = new Date(now.getTime());

  // 1) Día relativo.
  if (/\bantes\s+de\s+ayer\b|\banteayer\b|\babans[-\s]?d['e]?\s*ahir\b/.test(t)) {
    d.setDate(d.getDate() - 2); hasDate = true;
  } else if (/\bayer\b|\bahir\b/.test(t)) {
    d.setDate(d.getDate() - 1); hasDate = true;
  } else if (/\bhoy\b|\bavui\b/.test(t)) {
    hasDate = true;
  } else if (/\bmanana\b|\bdema\b/.test(t)) {
    d.setDate(d.getDate() + 1); hasDate = true;
  }

  // 2) Fecha explícita "el 5 de junio [de 2026]".
  let m = t.match(/\b(\d{1,2})\s+de\s+([a-z]+)(?:\s+de\s+(\d{4}))?/);
  if (m) {
    const day = parseInt(m[1], 10);
    const mon = MONTHS_WHEN[m[2]] || MONTHS_WHEN[`${m[2]}_ca`];
    if (mon && day >= 1 && day <= 31) {
      d.setFullYear(m[3] ? parseInt(m[3], 10) : d.getFullYear(), mon - 1, day);
      hasDate = true;
    }
  } else {
    // 2b) "5/6" o "5/6/2026" o "5-6".
    m = t.match(/\b(\d{1,2})[/-](\d{1,2})(?:[/-](\d{2,4}))?\b/);
    if (m) {
      const day = parseInt(m[1], 10); const mon = parseInt(m[2], 10);
      if (day >= 1 && day <= 31 && mon >= 1 && mon <= 12) {
        let yr = d.getFullYear();
        if (m[3]) yr = m[3].length === 2 ? 2000 + parseInt(m[3], 10) : parseInt(m[3], 10);
        d.setFullYear(yr, mon - 1, day); hasDate = true;
      }
    }
  }

  // 3) Hora. Primero formato HH:MM / HH.MM / HHh.
  let hh = null; let mm = 0;
  let tm = t.match(/\b(\d{1,2})[:.h](\d{2})\b/);
  if (tm) { hh = parseInt(tm[1], 10); mm = parseInt(tm[2], 10); }
  else {
    // "a las 3", "a les 9", "a las tres" (+ modificadores).
    tm = t.match(/\ba\s+l(?:as|es)\s+(\d{1,2}|[a-z]+)/);
    if (tm) {
      const tok = tm[1];
      hh = /^\d+$/.test(tok) ? parseInt(tok, 10) : (WORD_HOURS[tok] ?? null);
    } else if (/\bmediodia\b/.test(t)) { hh = 12; }
    else if (/\bmedianoche\b|\bmitjanit\b/.test(t)) { hh = 0; }
  }
  if (hh != null && hh >= 0 && hh <= 24) {
    if (/\by\s+media\b|\bi\s+mitja\b/.test(t)) mm = 30;
    else if (/\by\s+cuarto\b|\bi\s+quart\b/.test(t)) mm = 15;
    else if (/\bmenos\s+cuarto\b|\bmenys\s+quart\b/.test(t)) { hh = (hh + 23) % 24; mm = 45; }
    // Franja: "de la tarde/noche" -> +12 si es 1-11.
    if (/\bde\s+la\s+tarde\b|\bde\s+la\s+noche\b|\bde\s+la\s+nit\b|\bde\s+la\s+tarda\b/.test(t)
        && hh >= 1 && hh <= 11) hh += 12;
    if (hh === 24) hh = 0;
    if (mm >= 0 && mm < 60 && hh >= 0 && hh <= 23) {
      d.setHours(hh, mm, 0, 0); hasTime = true;
    }
  }

  if (!hasDate && !hasTime) return null;
  return d.toISOString();
}

// vocab (opcional): { clients: [...], places: [...] } ya usados por la empresa,
// para reconocer sus clientes y partir rutas sin conector ("Hospital Figueres
// Estació Girona").
export function parseTransactionText(text, vocab = {}) {
  const norm = normalize(text);
  const tokens = norm.split(' ').filter(Boolean);
  const words = new Set(tokens);
  const has = (list) => list.some((w) => words.has(w));

  const amount = extractAmount(tokens);
  const odometer_km = extractKm(tokens);
  // "empresa X" dicho explícitamente tiene prioridad; luego clientes de la propia
  // empresa y empresas conocidas (exacto y, si no, difuso para tolerar la voz:
  // "gitasi" -> Gitaxi).
  const client_name = extractCompany(text) || vocabClient(norm, tokens, vocab?.clients)
    || findClient(norm) || fuzzyClient(tokens);

  // Categoría de GASTO por palabra clave (gasolina, taller, peaje…).
  let category = findCategory(tokens);

  // La ruta solo tiene sentido en carreras (ingresos): si la frase es un gasto
  // con categoría, ignoramos cualquier "de X a Y" para no inventar origen/destino.
  // Las palabras del cliente no cuentan como lugar ("Figueres Girona Gitaxi").
  let { origin, destination, guess: route_guess = false } = category
    ? { origin: null, destination: null }
    : extractRoute(text, {
      places: vocab?.places,
      clients: [...(vocab?.clients || []), ...(client_name ? [client_name] : [])],
    });

  // Parece una carrera si hay ruta o cliente identificado.
  const looksLikeTrip = (!!origin && !!destination) || client_name != null;

  const payment_method = findPayment(tokens);

  // Tipo: la mayoría de dictados son carreras, así que INGRESO por defecto.
  // Gasto si hay categoría de gasto o palabra inequívoca (gasto/despesa/compra),
  // o un "pagué/pagat" sin forma de pago ni pinta de carrera ("pagué 15").
  // type_confident: el tipo sale de una palabra explícita (no de la suposición
  // por defecto); mergeParsed lo usa para que el LLM no lo pise.
  let type;
  let type_confident = true;
  if (has(INCOME_WORDS)) type = 'income';
  else if (category || has(STRONG_EXPENSE_WORDS)) type = 'expense';
  else if (has(PAY_VERBS) && !payment_method && !looksLikeTrip) type = 'expense';
  else {
    // Ingreso: seguro si hay cliente o ruta real (no supuesta); si no, suposición.
    type = 'income';
    type_confident = client_name != null || (!!origin && !!destination && !route_guess);
  }

  // Categoría por defecto para ingresos "simples" (sin ruta ni cliente).
  if (!category && type === 'income' && !looksLikeTrip) category = 'ingreso_tarjeta';

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
    created_at: extractWhen(text),
    type_confident,
    route_guess,
    missing_fields,
  };
}

// ¿Hace falta el LLM? No, si el determinista ya lo tiene todo y no queda en la
// frase ninguna palabra "de contenido" sin explicar (un lugar o empresa que no
// haya sabido colocar). Así se ahorran llamadas (cuota diaria de Groq) y el LLM
// solo entra en las frases difíciles: "carrera a l'aeroport", "Sant Pere
// Pescador Figueres", una empresa desconocida…
export function needsLlm(text, det, vocab = {}) {
  if (!det || det.amount == null || det.route_guess) return true;
  if (det.type === 'expense' ? !det.category : !det.payment_method) return true;
  const norm = (s) => normalize(s || '').split(' ').map(normToken);
  const explained = new Set([
    ...norm(det.origin), ...norm(det.destination), ...norm(det.client_name),
    ...(vocab.clients || []).flatMap(norm),
  ].map((t) => t.replace(/^[ld]['’]/, '')));
  return rawTokens(text).some((t) => isPlaceWord(t, explained));
}

export default parseTransactionText;
