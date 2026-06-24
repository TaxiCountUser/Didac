// ============================================================
// TaxiCount - Extracción de carreras con LLM (catalán y castellano).
//
// El parser de reglas (parser.js) es rápido y gratis pero frágil con lenguaje
// libre, sobre todo en catalán (origen/destino/empresa). Aquí usamos un LLM
// (compatible con la API de OpenAI; p. ej. Groq, GRATIS) para extraer los
// campos de forma robusta en ambos idiomas. Si el LLM falla o está desactivado,
// el endpoint cae al parser determinista.
// ============================================================

const PAY = new Set(['tarjeta', 'efectivo', 'bizum', 'transferencia']);
const CATS = new Set([
  'gasolina', 'gasoil', 'taller', 'peaje', 'parking', 'lavado',
  'multa', 'seguro', 'comida', 'compra',
]);

function capFirst(s) {
  if (s == null) return null;
  const t = String(s).trim();
  return t ? t.charAt(0).toUpperCase() + t.slice(1) : null;
}

const SYSTEM_PROMPT = `Ets un assistent que extreu dades d'una frase dita per un taxista, en CATALÀ o CASTELLÀ. La frase descriu una carrera (ingrés) o una despesa.

Retorna NOMÉS un objecte JSON (sense text addicional) amb aquestes claus exactes:
- "type": "income" si és una carrera/cobrament, "expense" si és una despesa/gasto.
- "amount": número en euros (decimals amb punt, p. ex. 18.5) o null. Compte amb els milers: "292.000" = 292000.
- "payment_method": un de "tarjeta", "efectivo", "bizum", "transferencia" o null. (targeta/visa/tpv/datàfon => tarjeta; efectiu/metàl·lic/monedes/bitllets => efectivo)
- "origin": lloc d'origen de la carrera (string) o null.
- "destination": lloc de destí (string) o null.
- "odometer_km": km actuals del cotxe (enter) o null. Només si es mencionen km/quilòmetres.
- "client_name": nom de l'empresa si es menciona (p. ex. Gitaxi, Movitaxi, OneCab, Asepeyo, Mutua Asepeyo, Radio Taxi, Cooperativa), amb la primera lletra en majúscula; null si és un client particular.
- "category": NOMÉS per a despeses, un de "gasolina", "gasoil", "taller", "peaje", "parking", "lavado", "multa", "seguro", "comida", "compra"; o null.

Regles: escriu els llocs i l'empresa amb majúscula inicial. Si un camp no apareix clarament, posa null. No inventis. Respon només amb el JSON.`;

/**
 * Extrae los campos de la transcripción usando un LLM compatible con OpenAI.
 * Lanza si el LLM no responde JSON válido (el llamador hace fallback).
 */
export async function llmParse(text, { apiKey, baseURL, model, language } = {}) {
  if (!apiKey || !model) throw new Error('LLM no configurado');
  const { default: OpenAI } = await import('openai');
  const client = new OpenAI({ apiKey, ...(baseURL ? { baseURL } : {}) });

  const userMsg = language
    ? `Idioma probable: ${language}.\nFrase: ${text}`
    : `Frase: ${text}`;

  const res = await client.chat.completions.create({
    model,
    temperature: 0,
    response_format: { type: 'json_object' },
    messages: [
      { role: 'system', content: SYSTEM_PROMPT },
      { role: 'user', content: userMsg },
    ],
  });
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
  };
  const missing_fields = [];
  if (m.amount == null) missing_fields.push('amount');
  if (m.type === 'expense' && !m.category) missing_fields.push('category');
  if (!m.payment_method) missing_fields.push('payment_method');
  m.missing_fields = missing_fields;
  return m;
}

export default llmParse;
