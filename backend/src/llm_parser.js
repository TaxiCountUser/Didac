// ============================================================
// TaxiCount - Extracción de carreras con LLM (catalán y castellano).
//
// El parser de reglas (parser.js) es rápido y gratis pero frágil con lenguaje
// libre, sobre todo en catalán (origen/destino/empresa). Aquí usamos un LLM
// (compatible con la API de OpenAI; p. ej. Groq, GRATIS) para extraer los
// campos de forma robusta en ambos idiomas. Si el LLM falla o está desactivado,
// el endpoint cae al parser determinista.
// ============================================================

const PAY = new Set(['tarjeta', 'efectivo', 'bizum', 'transferencia', 'credito']);
const CATS = new Set([
  'gasolina', 'gasoil', 'carga_electrica', 'taller', 'peaje', 'parking', 'lavado',
  'multa', 'seguro', 'autonomos', 'seguridad_social', 'comida', 'compra',
]);

function capFirst(s) {
  if (s == null) return null;
  const t = String(s).trim();
  return t ? t.charAt(0).toUpperCase() + t.slice(1) : null;
}

const SYSTEM_PROMPT = `Ets un assistent que extreu dades d'una frase dita per un taxista, en CATALÀ o CASTELLÀ. La frase descriu una carrera (ingrés) o una despesa.

Retorna NOMÉS un objecte JSON (sense text addicional) amb aquestes claus exactes:
- "type": "income" si és una carrera/cobrament, "expense" si és una despesa/gasto.
- "amount": el PREU de la carrera/despesa en EUROS que es paga (decimals amb punt, p. ex. 18.5), o null. NO són els quilòmetres. Si la frase NO esmenta cap preu en euros, ha de ser null (no l'inventis ni el dedueixis dels km). Compte amb els milers: "292.000" = 292000.
- "payment_method": un de "tarjeta", "efectivo", "bizum", "transferencia", "credito" o null. (targeta/visa/tpv/datàfon => tarjeta; efectiu/metàl·lic/monedes/bitllets => efectivo; fiat/pendent de cobrament/factura/a deure => credito)
- "origin": lloc d'origen de la carrera (string) o null.
- "destination": lloc de destí (string) o null.
- "odometer_km": km actuals del cotxe (enter) o null. Només si es mencionen km/quilòmetres.
- "client_name": nom de l'empresa si es menciona (p. ex. Gitaxi, Movitaxi, OneCab, Asepeyo, Mutua Asepeyo, Radio Taxi, Cooperativa), amb la primera lletra en majúscula; null si és un client particular. Si s'assembla molt a una empresa coneguda encara que la veu l'hagi transcrit malament (p. ex. "gitasi"/"gitaxis" -> "Gitaxi", "onecap" -> "OneCab"), normalitza'l al nom correcte de la llista.
- "category": NOMÉS per a despeses, un de "gasolina", "gasoil", "carga_electrica" (recàrrega elèctrica del cotxe), "taller", "peaje", "parking", "lavado", "multa", "seguro", "autonomos" (quota d'autònoms/TGSS), "seguridad_social" (SS/nòmina de conductors assalariats), "comida", "compra"; o null.

IMPORTANT amb els LLOCS: poden contenir preposicions, articles i diverses paraules i s'han de mantenir SENCERS, p. ex. "Rambla de Figueres", "Estació de França", "Estació de Renfe", "Museu Dalí", "Estació Figueres AVE", "Plaça de Catalunya". El "de/des de X a/fins a Y" que separa ORIGEN i DESTÍ és només el connector; aquest "de"/"a" de connexió NO forma part del nom. Exemple: "de la rambla de Figueres a l'estació de Renfe" => origin "Rambla de Figueres", destination "Estació de Renfe".

Regles: escriu els llocs i l'empresa amb majúscula inicial. Si un camp NO apareix clarament a la frase, posa null; no inventis ni dedueixis cap valor que no s'hagi dit (especialment l'import). Respon només amb el JSON.`;

/**
 * Extrae los campos de la transcripción usando un LLM compatible con OpenAI.
 * Lanza si el LLM no responde JSON válido (el llamador hace fallback).
 */
export async function llmParse(text, { apiKey, baseURL, model, language, onRateLimit } = {}) {
  if (!apiKey || !model) throw new Error('LLM no configurado');
  const { default: OpenAI } = await import('openai');
  const client = new OpenAI({ apiKey, ...(baseURL ? { baseURL } : {}) });

  const userMsg = language
    ? `Idioma probable: ${language}.\nFrase: ${text}`
    : `Frase: ${text}`;

  // withResponse() da acceso a las cabeceras (x-ratelimit-*) para el monitor de uso.
  const { data: res, response } = await client.chat.completions.create({
    model,
    temperature: 0,
    response_format: { type: 'json_object' },
    messages: [
      { role: 'system', content: SYSTEM_PROMPT },
      { role: 'user', content: userMsg },
    ],
  }).withResponse();
  if (onRateLimit && response?.headers) { try { onRateLimit(response.headers, model); } catch { /* no-op */ } }
  const raw = res.choices?.[0]?.message?.content || '{}';
  return sanitize(JSON.parse(raw));
}

// Normaliza/valida el JSON del LLM a nuestro esquema (valores fuera de rango -> null).
function sanitize(o) {
  o = o && typeof o === 'object' ? o : {};
  const type = o.type === 'income' || o.type === 'expense' ? o.type : null;

  let amount = null;
  if (typeof o.amount === 'number' && Number.isFinite(o.amount)) amount = o.amount;
  else if (o.amount != null && !Number.isNaN(parseFloat(o.amount))) amount = parseFloat(o.amount);

  let odometer_km = null;
  if (o.odometer_km != null && !Number.isNaN(parseInt(o.odometer_km, 10))) {
    odometer_km = parseInt(o.odometer_km, 10);
  }

  return {
    type,
    amount,
    payment_method: PAY.has(o.payment_method) ? o.payment_method : null,
    origin: o.origin ? capFirst(o.origin) : null,
    destination: o.destination ? capFirst(o.destination) : null,
    odometer_km,
    client_name: o.client_name ? capFirst(o.client_name) : null,
    category: CATS.has(o.category) ? o.category : null,
  };
}

/**
 * Combina el resultado del LLM con el determinista: prioriza el LLM, y para
 * cualquier campo que el LLM deje en null usa el determinista como respaldo.
 * Recalcula missing_fields sobre el resultado combinado.
 */
export function mergeParsed(llm, det) {
  const pick = (a, b) => (a !== null && a !== undefined ? a : b);
  const m = {
    amount: pick(llm.amount, det.amount),
    category: pick(llm.category, det.category),
    type: pick(llm.type, det.type),
    payment_method: pick(llm.payment_method, det.payment_method),
    origin: pick(llm.origin, det.origin),
    destination: pick(llm.destination, det.destination),
    odometer_km: pick(llm.odometer_km, det.odometer_km),
    client_name: pick(llm.client_name, det.client_name),
    // Fecha/hora dichas: la detecta el parser determinista (det); el LLM no la
    // extrae. Si no se dijo, queda null y el frontend usa la fecha/hora actual.
    created_at: pick(llm.created_at, det.created_at),
  };
  const missing_fields = [];
  if (m.amount == null) missing_fields.push('amount');
  if (m.type === 'expense' && !m.category) missing_fields.push('category');
  if (!m.payment_method) missing_fields.push('payment_method');
  m.missing_fields = missing_fields;
  return m;
}

/**
 * Identifica qué columna de una hoja de cálculo es cada campo, a partir de las
 * primeras filas (cada fila es un array de celdas por índice). Devuelve
 * { headerRow, columns:{ date,amount,type,income,expense,category,description,
 * payment,driver,plate } } con índices de columna o null. La IA SOLO mapea
 * columnas; el cálculo de los valores lo hace el código (no inventa cifras).
 */
export async function llmMapColumns(sampleRows, { apiKey, baseURL, model } = {}) {
  if (!apiKey || !model) throw new Error('LLM no configurado');
  const { default: OpenAI } = await import('openai');
  const client = new OpenAI({ apiKey, ...(baseURL ? { baseURL } : {}) });

  const sys = `Eres un asistente que identifica las columnas de una hoja de cálculo de un taxista (ingresos y gastos). Te paso las primeras filas; cada fila es un array de celdas indexadas desde 0.
Devuelve SOLO un JSON con esta forma exacta:
{"headerRow": <índice de la fila de títulos, o -1 si no hay títulos>,
 "columns": {"date": <idx|null>, "amount": <idx|null>, "type": <idx|null>, "income": <idx|null>, "expense": <idx|null>, "category": <idx|null>, "description": <idx|null>, "payment": <idx|null>, "driver": <idx|null>, "plate": <idx|null>}}
Significado: date=fecha; amount=importe único; type=columna con ingreso/gasto; income=columna SOLO de ingresos; expense=columna SOLO de gastos; category=categoría/concepto; description=descripción/notas; payment=forma de pago; driver=conductor; plate=matrícula.
Usa el índice numérico de columna. Si un campo no existe, null. No inventes columnas.`;

  const table = sampleRows
    .map((r, i) => `Fila ${i}: ${JSON.stringify(r)}`)
    .join('\n');

  const res = await client.chat.completions.create({
    model,
    temperature: 0,
    response_format: { type: 'json_object' },
    messages: [
      { role: 'system', content: sys },
      { role: 'user', content: table },
    ],
  });
  const raw = res.choices?.[0]?.message?.content || '{}';
  const o = JSON.parse(raw);
  const cols = (o && typeof o.columns === 'object') ? o.columns : {};
  const idx = (v) => (typeof v === 'number' && v >= 0 ? v : null);
  return {
    headerRow: typeof o.headerRow === 'number' ? o.headerRow : -1,
    columns: {
      date: idx(cols.date), amount: idx(cols.amount), type: idx(cols.type),
      income: idx(cols.income), expense: idx(cols.expense),
      category: idx(cols.category), description: idx(cols.description),
      payment: idx(cols.payment), driver: idx(cols.driver), plate: idx(cols.plate),
    },
  };
}

export default llmParse;
