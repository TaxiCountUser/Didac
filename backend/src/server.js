import 'dotenv/config';
import { pathToFileURL } from 'node:url';
import { randomBytes, createHash } from 'node:crypto';
import Fastify from 'fastify';
import cors from '@fastify/cors';
import multipart from '@fastify/multipart';
import { createClient } from '@supabase/supabase-js';

import { parseTransactionText } from './parser.js';
import { parseImportFile } from './importer.js';
import { llmMapColumns } from './llm_parser.js';
import { correctTranscript } from './corrections.js';
import { llmParse, mergeParsed } from './llm_parser.js';
import { sendToTokens, pushEnabled } from './push.js';
import { applyStripeEvent, planForPrice } from './billing.js';
import {
  fetchReportData,
  buildExcel,
  buildPdf,
  cacheKey,
  getCached,
  setCached,
} from './reports.js';

const REPORT_TIMEOUT_MS = Number(process.env.REPORT_TIMEOUT_MS || 30000);
const XLSX_MIME = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

// Render/Railway/Fly inyectan PORT; en local usamos BACKEND_PORT (3000).
const PORT = Number(process.env.BACKEND_PORT || process.env.PORT || 3000);
const HOST = '0.0.0.0';

// Normaliza la URL de Supabase: si viene sin protocolo (p. ej. "xxx.supabase.co"),
// le ponemos https:// para no romper createClient ("Invalid supabaseUrl").
const _rawSupabaseUrl = (process.env.SUPABASE_URL || '').trim();
const SUPABASE_URL = _rawSupabaseUrl
    ? (/^https?:\/\//i.test(_rawSupabaseUrl) ? _rawSupabaseUrl : `https://${_rawSupabaseUrl}`)
    : 'http://kong:8000';
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || '';
const OPENAI_API_KEY = process.env.OPENAI_API_KEY || '';
// Proveedor de transcripción compatible con la API de OpenAI. Por defecto OpenAI
// (modelo whisper-1). Para usar una alternativa GRATIS como Groq, define:
//   OPENAI_BASE_URL=https://api.groq.com/openai/v1
//   WHISPER_MODEL=whisper-large-v3
//   OPENAI_API_KEY=<tu clave de Groq>
const OPENAI_BASE_URL = process.env.OPENAI_BASE_URL || '';
const WHISPER_MODEL = process.env.WHISPER_MODEL || 'whisper-1';
// LLM para interpretar la transcripción (origen/destino/empresa) en catalán y
// castellano. Vacío = solo parser determinista. Con Groq (gratis) usa un modelo
// de chat, p. ej. llama-3.3-70b-versatile.
const LLM_PARSE_MODEL = process.env.LLM_PARSE_MODEL || '';
const LLM_PARSE_TIMEOUT_MS = Number(process.env.LLM_PARSE_TIMEOUT_MS || 8000);
// Endpoint de prueba (escribir una frase y ver cómo se interpreta) SIN audio.
// Solo se activa con ENABLE_PARSE_TEST=true (apágalo en producción real).
const ENABLE_PARSE_TEST = process.env.ENABLE_PARSE_TEST === 'true';

// Datos para la política de privacidad (Google Play exige una URL pública).
const PRIVACY_COMPANY = process.env.PRIVACY_COMPANY || 'TaxiCount';
const PRIVACY_CONTACT = process.env.PRIVACY_CONTACT || 'didakdp.5@gmail.com';

// Política de privacidad (HTML). Honesta con lo que hace la app: cuenta, GPS de
// conductores, audio de voz enviado a un transcriptor (Groq/OpenAI) y datos de
// actividad. Empresa/contacto configurables por env.
function privacyHtml() {
  return `<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Política de privacidad · TaxiCount</title>
<style>body{font-family:system-ui,Arial,sans-serif;max-width:760px;margin:24px auto;padding:0 16px;color:#222;line-height:1.5}h1{font-size:22px}h2{font-size:17px;margin-top:24px}code{background:#f2f2f2;padding:1px 4px;border-radius:4px}</style>
</head><body>
<h1>Política de privacidad de TaxiCount</h1>
<p><em>Última actualización: 24 de junio de 2026</em></p>
<p>Esta política explica qué datos trata la aplicación <strong>TaxiCount</strong> (gestión de flota de taxi) y con qué fin. Responsable del tratamiento: <strong>${PRIVACY_COMPANY}</strong>. Contacto: <strong>${PRIVACY_CONTACT}</strong>.</p>

<h2>1. Datos que tratamos</h2>
<ul>
  <li><strong>Cuenta</strong>: correo electrónico, nombre y, si lo indicas, número de licencia.</li>
  <li><strong>Ubicación (GPS)</strong>: de los conductores, mientras la app está abierta, para que el titular de la flota pueda localizar el vehículo durante la jornada laboral.</li>
  <li><strong>Audio de voz</strong>: cuando usas el registro por voz, el audio se envía a un proveedor de transcripción (Groq u OpenAI) para convertirlo en texto. El audio no se almacena de forma permanente; solo se guarda el texto/los datos de la carrera.</li>
  <li><strong>Actividad</strong>: carreras, importes, gastos, kilómetros, vehículos e incidencias que registras.</li>
</ul>

<h2>2. Para qué los usamos</h2>
<p>Para prestar el servicio: registrar carreras y gastos, calcular informes, gestionar vehículos y conductores, y permitir al titular de la flota el seguimiento operativo. No vendemos tus datos ni los usamos para publicidad.</p>

<h2>3. Base legal</h2>
<p>Ejecución del servicio contratado y, para la ubicación y el micrófono, tu consentimiento (puedes revocarlo en los ajustes del móvil).</p>

<h2>4. Proveedores que tratan datos por nuestra cuenta</h2>
<ul>
  <li><strong>Supabase</strong> — base de datos, autenticación y almacenamiento.</li>
  <li><strong>Groq / OpenAI</strong> — transcripción de las notas de voz.</li>
  <li><strong>Stripe</strong> — pagos de la suscripción (si procede).</li>
  <li><strong>Render</strong> — alojamiento del servidor.</li>
</ul>
<p>Algunos pueden tratar datos fuera de la UE con las garantías legales aplicables.</p>

<h2>5. Conservación</h2>
<p>Conservamos los datos mientras la cuenta esté activa. Puedes solicitar su supresión escribiendo a ${PRIVACY_CONTACT}.</p>

<h2>6. Tus derechos (RGPD)</h2>
<p>Acceso, rectificación, supresión, oposición, limitación y portabilidad, escribiendo a ${PRIVACY_CONTACT}. También puedes reclamar ante la Agencia Española de Protección de Datos (AEPD).</p>

<h2>7. Permisos del dispositivo</h2>
<p>La app pide <strong>ubicación</strong> (seguimiento del vehículo) y <strong>micrófono</strong> (registro por voz). Son opcionales y revocables desde los ajustes del sistema.</p>

<h2>8. Menores</h2>
<p>TaxiCount es una herramienta profesional y no está dirigida a menores de edad.</p>

<h2>9. Cambios</h2>
<p>Si actualizamos esta política, publicaremos la nueva versión en esta misma dirección.</p>
</body></html>`;
}

// Página web mínima para probar la interpretación desde el navegador.
const PARSE_TEST_HTML = `<!doctype html>
<html lang="ca"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>TaxiCount · Prova d'interpretació</title>
<style>
 body{font-family:system-ui,Arial,sans-serif;max-width:680px;margin:24px auto;padding:0 16px;color:#222}
 h1{font-size:20px} textarea{width:100%;height:90px;font-size:16px;padding:8px;box-sizing:border-box}
 select,button{font-size:16px;padding:8px}
 button{background:#f5a623;border:0;border-radius:8px;color:#fff;font-weight:600;cursor:pointer}
 pre{background:#111;color:#0f0;padding:12px;border-radius:8px;overflow:auto;white-space:pre-wrap}
 .row{display:flex;gap:8px;align-items:center;margin:8px 0} .ex{color:#777;font-size:13px}
</style></head><body>
<h1>🚕 TaxiCount · Prova d'interpretació</h1>
<p class="ex">Escriu una frase com la diries de viva veu i mira com s'interpreta (origen, destí, import, empresa, km, pagament). Ctrl+Enter per provar.</p>
<textarea id="t" placeholder="cursa des de la rambla de Figueres fins al museu Dalí, vint euros amb targeta, gitaxi"></textarea>
<div class="row">Idioma:
  <select id="lang"><option value="ca">Català</option><option value="es">Castellà</option><option value="en">English</option></select>
  <button id="go">Provar</button></div>
<pre id="out">El resultat sortirà aquí…</pre>
<script>
 const out=document.getElementById('out'), go=document.getElementById('go');
 async function run(){
   out.textContent='Interpretant…';
   try{
     const r=await fetch('/api/v1/parse-test',{method:'POST',headers:{'Content-Type':'application/json'},
       body:JSON.stringify({text:document.getElementById('t').value,language:document.getElementById('lang').value})});
     const j=await r.json(); out.textContent=JSON.stringify(j.parsed||j,null,2);
   }catch(e){ out.textContent='Error: '+e.message; }
 }
 go.addEventListener('click',run);
 document.getElementById('t').addEventListener('keydown',e=>{ if(e.key==='Enter'&&(e.ctrlKey||e.metaKey)) run(); });
</script></body></html>`;

const SENTRY_DSN = process.env.SENTRY_DSN || '';
const STRIPE_SECRET_KEY = process.env.STRIPE_SECRET_KEY || '';
const STRIPE_WEBHOOK_SECRET = process.env.STRIPE_WEBHOOK_SECRET || '';
const STRIPE_SUCCESS_URL = process.env.STRIPE_SUCCESS_URL || 'taxicount://subscription-success';
const STRIPE_CANCEL_URL = process.env.STRIPE_CANCEL_URL || 'taxicount://subscription-cancel';

const DAILY_LIMIT = Number(process.env.TRANSCRIBE_DAILY_LIMIT || 150);
const WHISPER_TIMEOUT_MS = Number(process.env.WHISPER_TIMEOUT_MS || 15000);
// Hook SOLO para desarrollo/tests: permite enviar mock_text sin llamar a Whisper.
const ALLOW_MOCK = process.env.ALLOW_MOCK_TRANSCRIBE === 'true';

function generateTempPassword() {
  return 'Tx' + randomBytes(9).toString('base64url') + '9!';
}

function withTimeout(promise, ms) {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error('whisper-timeout')), ms)),
  ]);
}

// Transcriptor real (Whisper). Compatible con OpenAI o cualquier proveedor con
// API compatible (p. ej. Groq, gratis). Import dinámico para no exigir el
// paquete cuando se usa un mock en tests.
async function defaultTranscribe({ buffer, filename, language }) {
  if (!OPENAI_API_KEY) throw new Error('OPENAI_API_KEY no configurada');
  const { default: OpenAI, toFile } = await import('openai');
  const client = new OpenAI({
    apiKey: OPENAI_API_KEY,
    ...(OPENAI_BASE_URL ? { baseURL: OPENAI_BASE_URL } : {}),
  });
  const file = await toFile(buffer, filename || 'audio.m4a');
  // Pista de idioma (es/ca/en): mejora mucho catalán y frases cortas.
  // Pista de vocabulario (prompt): sesga a términos locales para que no parta
  // nombres propios (p. ej. "Museu Dalí" en vez de "museu de lí"). Ampliable
  // con TRANSCRIBE_PROMPT.
  const prompt = process.env.TRANSCRIBE_PROMPT
    || 'Carrera de taxi a Figueres. Llocs: Museu Dalí, Rambla de Figueres, Estació de Renfe, Estació Figueres-Vilafant AVE, Castell de Sant Ferran. Empreses: Gitaxi, Movitaxi, OneCab.';
  const res = await client.audio.transcriptions.create({
    file,
    model: WHISPER_MODEL,
    prompt,
    ...(language ? { language } : {}),
  });
  return { text: res.text, confidence: 0.95 };
}

// Idiomas soportados como pista para Whisper (ISO-639-1).
const TRANSCRIBE_LANGS = new Set(['es', 'ca', 'en']);

// Interpreta la transcripción: si hay LLM configurado lo usa (mejor en catalán)
// y completa con el parser determinista; si no, solo el determinista. Nunca
// lanza: ante cualquier fallo del LLM, devuelve el resultado determinista.
// Si no se dijo ningún precio, anotamos 0 (NO se inventa) para que un importe de
// 0 € en la lista sea la señal visible de que esa carrera hay que revisarla.
function zeroIfNoAmount(parsed) {
  if (parsed.amount == null) {
    parsed.amount = 0;
    parsed.missing_fields = (parsed.missing_fields || []).filter((f) => f !== 'amount');
  }
  return parsed;
}

async function parseSmart(text, { language, log } = {}) {
  const deterministic = parseTransactionText(text);
  if (!LLM_PARSE_MODEL || !OPENAI_API_KEY) return zeroIfNoAmount(deterministic);
  try {
    const llm = await withTimeout(
      llmParse(text, {
        apiKey: OPENAI_API_KEY,
        baseURL: OPENAI_BASE_URL,
        model: LLM_PARSE_MODEL,
        language,
      }),
      LLM_PARSE_TIMEOUT_MS,
    );
    return zeroIfNoAmount(mergeParsed(llm, deterministic));
  } catch (e) {
    log?.warn?.(`LLM parse falló (${e.message}); uso parser determinista`);
    return zeroIfNoAmount(deterministic);
  }
}

/**
 * @param {object} [options]
 * @param {(input:{buffer?:Buffer,filename?:string,mockText?:string})=>Promise<{text:string,confidence:number}>} [options.transcribe]
 *        Permite inyectar un transcriptor (mock) en tests.
 */
export async function buildApp(options = {}) {
  const app = Fastify({ logger: process.env.NODE_ENV !== 'test' });

  // Sentry (Fase 6): solo si hay DSN configurado. En tests no se carga.
  if (SENTRY_DSN) {
    const Sentry = await import('@sentry/node');
    Sentry.init({
      dsn: SENTRY_DSN,
      environment: process.env.NODE_ENV || 'production',
      tracesSampleRate: Number(process.env.SENTRY_TRACES_SAMPLE_RATE || 0.1),
    });
    Sentry.setupFastifyErrorHandler(app);
    app.log.info('[sentry] captura de errores activada');
  }

  const corsOrigin = process.env.CORS_ORIGIN ? process.env.CORS_ORIGIN.split(',') : true;
  await app.register(cors, { origin: corsOrigin });
  await app.register(multipart, { limits: { fileSize: 25 * 1024 * 1024 } });

  // Parser de JSON que además conserva el cuerpo en crudo (req.rawBody) para
  // poder verificar la firma del webhook de Stripe sobre los bytes exactos.
  app.addContentTypeParser('application/json', { parseAs: 'buffer' }, (req, body, done) => {
    req.rawBody = body;
    if (!body || body.length === 0) return done(null, {});
    try {
      done(null, JSON.parse(body.toString('utf8')));
    } catch {
      // El webhook usa rawBody; el resto tolera cuerpo vacío.
      done(null, {});
    }
  });

  const transcribe = options.transcribe || defaultTranscribe;

  // Cliente Stripe: inyectable en tests (options.stripe). En producción se crea
  // desde STRIPE_SECRET_KEY. La verificación de firma funciona sin red.
  let stripe = options.stripe || null;
  if (!stripe && STRIPE_SECRET_KEY) {
    const { default: Stripe } = await import('stripe');
    stripe = new Stripe(STRIPE_SECRET_KEY);
  }
  app.decorate('stripe', stripe);

  let supabase = null;
  if (SUPABASE_URL && SUPABASE_SERVICE_ROLE_KEY) {
    try {
      supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
        auth: { autoRefreshToken: false, persistSession: false },
      });
    } catch (e) {
      // URL o clave inválidas: no tumbamos el servidor, solo deshabilitamos
      // Supabase (los endpoints que lo necesiten responderán 500 claro).
      app.log.error(`Supabase deshabilitado (config inválida): ${e.message}`);
    }
  }
  app.decorate('supabase', supabase);

  // Caché de transcripciones en memoria: clave userId:hash(audio) -> {text,confidence}
  const transcriptionCache = new Map();

  // Verifica el JWT y devuelve el perfil del llamante (o null).
  async function getCaller(request) {
    const auth = request.headers['authorization'] || '';
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : null;
    if (!token || !supabase) return null;
    const { data, error } = await supabase.auth.getUser(token);
    if (error || !data?.user) return null;
    const { data: prof } = await supabase
      .from('users')
      .select('id, role, tenant_id, is_admin, daily_transcription_count, transcription_count_date')
      .eq('id', data.user.id)
      .single();
    return prof || null;
  }

  // Comprueba y actualiza el límite diario. Devuelve true si se permite.
  async function bumpDailyLimit(caller) {
    const today = new Date().toISOString().slice(0, 10);
    let count = caller.daily_transcription_count || 0;
    if (caller.transcription_count_date !== today) count = 0;
    if (count >= DAILY_LIMIT) return false;
    await supabase
      .from('users')
      .update({ daily_transcription_count: count + 1, transcription_count_date: today })
      .eq('id', caller.id);
    return true;
  }

  // --- Health ---
  app.get('/health', async () => ({
    status: 'ok',
    service: 'taxicount-backend',
    push: pushEnabled(),
    stripe: !!stripe,
    // IA (Groq/OpenAI) para voz e importación: necesaria para nombres de lugar
    // con preposiciones ("Rambla de Figueres") y para mapear Excels raros.
    llm: !!(OPENAI_API_KEY && LLM_PARSE_MODEL),
    timestamp: new Date().toISOString(),
  }));

  // Política de privacidad (URL pública requerida por Google Play).
  app.get('/privacy', async (_request, reply) => {
    reply.type('text/html').send(privacyHtml());
  });

  // --- Transcripción + parseo (Fase 2) ---
  app.post('/api/v1/transcribe', async (request, reply) => {
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });

    // Idioma del hablante (pista para Whisper): ?language=es|ca|en.
    const langRaw = (request.query?.language || '').toLowerCase();
    const language = TRANSCRIBE_LANGS.has(langRaw) ? langRaw : null;

    // Obtener el audio: multipart (campo 'audio'), o JSON { storagePath } / mock_text.
    let buffer = null;
    let filename = 'audio.m4a';
    let mockText = null;
    let storagePath = null;

    if (request.isMultipart()) {
      const file = await request.file();
      if (file?.fieldname === 'audio' || file) {
        filename = file.filename || filename;
        buffer = await file.toBuffer();
      }
    } else {
      const body = request.body || {};
      mockText = body.mock_text || null;
      storagePath = body.storagePath || null;
    }

    // Descargar de Supabase Storage si llega una ruta
    if (!buffer && !mockText && storagePath) {
      const { data, error } = await supabase.storage.from('voice-notes').download(storagePath);
      if (error || !data) return reply.code(400).send({ error: 'No se pudo descargar el audio' });
      buffer = Buffer.from(await data.arrayBuffer());
    }

    if (!buffer && !(ALLOW_MOCK && mockText)) {
      return reply.code(400).send({ error: 'Falta el audio' });
    }

    // Clave de caché
    const hash = createHash('sha256')
      .update(buffer || Buffer.from(`mock:${mockText}`))
      .digest('hex');
    const cacheKey = `${caller.id}:${hash}`;

    if (transcriptionCache.has(cacheKey)) {
      const cached = transcriptionCache.get(cacheKey);
      const parsed = await parseSmart(cached.text, { language, log: request.log });
      return reply.send({ ...cached, parsed, cached: true });
    }

    // Límite diario (solo cuando vamos a llamar de verdad a Whisper)
    const allowed = await bumpDailyLimit(caller);
    if (!allowed) {
      return reply.code(429).send({ error: 'Límite diario de transcripciones alcanzado' });
    }

    // Transcribir (mock o real) con timeout + un reintento
    let result;
    try {
      const run = () =>
        ALLOW_MOCK && mockText
          ? Promise.resolve({ text: mockText, confidence: 0.99 })
          : transcribe({ buffer, filename, language });
      try {
        result = await withTimeout(run(), WHISPER_TIMEOUT_MS);
      } catch (e) {
        request.log.warn(`Whisper falló (${e.message}); reintentando…`);
        result = await withTimeout(run(), WHISPER_TIMEOUT_MS);
      }
    } catch (e) {
      request.log.error(`Transcripción falló: ${e.message}`);
      // Fallback de DESARROLLO: si Whisper no está disponible (p. ej. sin una
      // OPENAI_API_KEY válida) y se permite el modo mock, devolvemos una
      // transcripción de ejemplo marcada como `mock` para poder probar el flujo
      // de voz en local. En producción, configura una API key real y pon
      // ALLOW_MOCK_TRANSCRIBE=false.
      if (ALLOW_MOCK) {
        const text = 'carrera de Sants a la Sagrera por 18 euros con tarjeta';
        const result = { text, confidence: 0 };
        transcriptionCache.set(cacheKey, result);
        return reply.send({ ...result, parsed: parseTransactionText(text), cached: false, mock: true });
      }
      const isKeyIssue = /api[ _-]?key|401|unauthor|incorrect|invalid/i.test(e.message || '');
      const error = isKeyIssue
        ? 'Transcripción de voz no disponible: falta configurar una API key válida de OpenAI (OPENAI_API_KEY). Usa el modo manual mientras tanto.'
        : 'Transcripción de voz no disponible ahora mismo. Usa el modo manual mientras tanto.';
      return reply.code(502).send({ error, detail: e.message });
    }

    // Corrige términos locales mal transcritos (p. ej. "museu de lí" -> "Museu
    // Dalí") antes de interpretar y de mostrar la descripción.
    result.text = correctTranscript(result.text);
    transcriptionCache.set(cacheKey, result);
    const parsed = await parseSmart(result.text, { language, log: request.log });
    return reply.send({ ...result, parsed, cached: false });
  });

  // --- Endpoint de PRUEBA (sin audio): escribe una frase y mira el parseo ---
  // Útil para validar catalán/castellano antes de probar con la voz real.
  // Solo activo si ENABLE_PARSE_TEST=true.
  if (ENABLE_PARSE_TEST) {
    app.post('/api/v1/parse-test', async (request, reply) => {
      const body = request.body || {};
      const text = (body.text || '').toString();
      if (!text.trim()) return reply.code(400).send({ error: 'Falta "text"' });
      const langRaw = (body.language || request.query?.language || '').toLowerCase();
      const language = TRANSCRIBE_LANGS.has(langRaw) ? langRaw : null;
      const corrected = correctTranscript(text);
      const parsed = await parseSmart(corrected, { language, log: request.log });
      return reply.send({ text: corrected, language, parsed });
    });

    // Pequeña página web para probar desde el navegador.
    app.get('/parse-test', async (_request, reply) => {
      reply.type('text/html').send(PARSE_TEST_HTML);
    });
  }

  // --- Invitar conductor (Fase 1) ---
  app.post('/api/v1/drivers', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (caller.role !== 'owner') {
      return reply.code(403).send({ error: 'Solo un Owner puede invitar conductores' });
    }

    const { email, name } = request.body ?? {};
    if (!email) return reply.code(400).send({ error: 'email es obligatorio' });

    // Límite de conductores según el plan contratado (Fase 4).
    const { data: tenant } = await supabase
      .from('tenants')
      .select('drivers_limit, subscription_status')
      .eq('id', caller.tenant_id)
      .single();
    const limit = tenant?.drivers_limit;
    // Durante la prueba gratuita (sin plan de pago activo) NO se aplica el límite:
    // así pueden probar la gestión de flota con varios conductores. El límite
    // solo cuenta con una suscripción de pago al día (active/past_due).
    const paid = tenant?.subscription_status === 'active' || tenant?.subscription_status === 'past_due';
    if (paid && limit !== null && limit !== undefined) {
      const { count } = await supabase
        .from('users')
        .select('id', { count: 'exact', head: true })
        .eq('tenant_id', caller.tenant_id)
        .eq('role', 'driver');
      if ((count ?? 0) >= limit) {
        return reply.code(403).send({ error: 'Has alcanzado el límite de conductores de tu plan' });
      }
    }

    // Pre-comprobación: si ya hay una cuenta con ese correo, avisamos claro
    // (si no, el trigger de alta falla con un error vacío y confuso).
    const emailNorm = String(email).trim().toLowerCase();
    const { data: dup } = await supabase
      .from('users')
      .select('id, tenant_id')
      .ilike('email', emailNorm)
      .maybeSingle();
    if (dup) {
      const msg = dup.tenant_id === caller.tenant_id
        ? 'Ya tienes un conductor con ese correo.'
        : 'Ese correo ya está registrado en TaxiCount; usa otro.';
      return reply.code(409).send({ error: msg });
    }

    const tempPassword = generateTempPassword();
    const { data: created, error: createErr } = await supabase.auth.admin.createUser({
      email,
      password: tempPassword,
      email_confirm: true,
      user_metadata: { role: 'driver', tenant_id: caller.tenant_id, name: name ?? null },
    });
    if (createErr) {
      const m = createErr.message || '';
      const dupErr = /already|registered|exists|duplicate|23505/i.test(m) || m === '{}' || m === '';
      return reply
        .code(dupErr ? 409 : 400)
        .send({ error: dupErr ? 'Ese correo ya está registrado; usa otro.' : m });
    }

    app.log.info(`[create-driver] ${email} en tenant ${caller.tenant_id}. Pwd temporal: ${tempPassword}`);
    return reply.code(201).send({ id: created.user.id, email, tenant_id: caller.tenant_id, tempPassword });
  });

  // Comprueba que el llamante es Owner y que `driverId` es un conductor de su
  // propio tenant. Devuelve {error, code} o {driver} (fila de public.users).
  async function ownerDriverGuard(request, driverId) {
    if (!supabase) return { code: 500, error: 'Supabase no configurado' };
    const caller = await getCaller(request);
    if (!caller) return { code: 401, error: 'No autenticado' };
    if (caller.role !== 'owner') return { code: 403, error: 'Solo un Owner puede gestionar conductores' };
    if (!driverId) return { code: 400, error: 'Falta el id del conductor' };
    const { data: driver, error } = await supabase
      .from('users')
      .select('id, role, tenant_id')
      .eq('id', driverId)
      .single();
    if (error || !driver) return { code: 404, error: 'Conductor no encontrado' };
    if (driver.tenant_id !== caller.tenant_id || driver.role !== 'driver') {
      return { code: 403, error: 'Ese conductor no pertenece a tu flota' };
    }
    return { caller, driver };
  }

  // --- Editar conductor: usuario, contraseña, nombre, activar/desactivar ---
  // El Owner define las credenciales del trabajador (para que pueda entrar con
  // usuario o correo + contraseña), corrige el nombre, o lo saca/devuelve a la
  // flota (active). Cambiar la contraseña requiere service_role (Admin API).
  app.patch('/api/v1/drivers/:id', async (request, reply) => {
    const driverId = request.params.id;
    const guard = await ownerDriverGuard(request, driverId);
    if (guard.error) return reply.code(guard.code).send({ error: guard.error });

    const { username, password, name, active } = request.body ?? {};

    // Contraseña (Admin API): mínimo 6 caracteres como exige GoTrue.
    if (password !== undefined && password !== null && password !== '') {
      if (String(password).length < 6) {
        return reply.code(400).send({ error: 'La contraseña debe tener al menos 6 caracteres' });
      }
      const { error: pErr } = await supabase.auth.admin.updateUserById(driverId, {
        password: String(password),
      });
      if (pErr) return reply.code(400).send({ error: `No se pudo cambiar la contraseña: ${pErr.message}` });
    }

    // Campos de public.users (service_role omite RLS).
    const patch = {};
    if (username !== undefined) {
      const u = (username == null ? '' : String(username)).trim();
      patch.username = u === '' ? null : u;
    }
    if (name !== undefined) {
      const n = (name == null ? '' : String(name)).trim();
      patch.name = n === '' ? null : n;
    }
    if (active !== undefined) patch.active = active === true || active === 'true';

    if (Object.keys(patch).length > 0) {
      const { error: uErr } = await supabase.from('users').update(patch).eq('id', driverId);
      if (uErr) {
        const dup = /duplicate|unique|23505/i.test(uErr.message || '');
        return reply
          .code(dup ? 409 : 400)
          .send({ error: dup ? 'Ese nombre de usuario ya está en uso' : uErr.message });
      }
    }

    return reply.send({ ok: true, id: driverId });
  });

  // --- Eliminar conductor (definitivo): borra su cuenta y sus datos ---
  app.delete('/api/v1/drivers/:id', async (request, reply) => {
    const driverId = request.params.id;
    const guard = await ownerDriverGuard(request, driverId);
    if (guard.error) return reply.code(guard.code).send({ error: guard.error });

    // Borrar la fila de perfil (cascada a sus datos por FK) y la cuenta de auth.
    await supabase.from('users').delete().eq('id', driverId);
    const { error: dErr } = await supabase.auth.admin.deleteUser(driverId);
    if (dErr && !/not.*found|404/i.test(dErr.message || '')) {
      return reply.code(400).send({ error: `No se pudo eliminar la cuenta: ${dErr.message}` });
    }
    return reply.send({ ok: true, id: driverId });
  });

  // ============================================================
  // Panel de administrador de plataforma (is_admin).
  // Ve y gestiona TODAS las empresas e incidencias. Va por service_role, pero
  // SIEMPRE verifica que el llamante es admin antes de devolver nada.
  // ============================================================
  async function adminGuard(request) {
    if (!supabase) return { code: 500, error: 'Supabase no configurado' };
    const caller = await getCaller(request);
    if (!caller) return { code: 401, error: 'No autenticado' };
    if (!caller.is_admin) return { code: 403, error: 'Solo un administrador puede acceder' };
    return { caller };
  }

  // Resumen de todas las empresas: datos + nº de usuarios + incidencias abiertas.
  app.get('/api/v1/admin/overview', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });

    const { data: tenants, error } = await supabase
      .from('tenants')
      .select('id, name, solo, subscription_status, plan_id, trial_ends_at, created_at')
      .order('created_at', { ascending: false });
    if (error) return reply.code(500).send({ error: error.message });

    const { data: users } = await supabase.from('users').select('id, tenant_id');
    const { data: openInc } = await supabase
      .from('incidents')
      .select('id, tenant_id')
      .eq('status', 'abierta');

    const usersByTenant = {};
    for (const u of users || []) usersByTenant[u.tenant_id] = (usersByTenant[u.tenant_id] || 0) + 1;
    const incByTenant = {};
    for (const i of openInc || []) incByTenant[i.tenant_id] = (incByTenant[i.tenant_id] || 0) + 1;

    const rows = (tenants || []).map((t) => ({
      ...t,
      users_count: usersByTenant[t.id] || 0,
      open_incidents: incByTenant[t.id] || 0,
    }));
    return reply.send({
      tenants: rows,
      totals: {
        tenants: rows.length,
        users: (users || []).length,
        open_incidents: (openInc || []).length,
      },
    });
  });

  // Todas las incidencias de todas las empresas (con nombre de empresa y autor).
  app.get('/api/v1/admin/incidents', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });

    const status = request.query?.status; // 'abierta' | 'resuelta' | undefined
    let q = supabase
      .from('incidents')
      .select('id, kind, body, status, created_at, tenant_id, user_id, hidden_for_tenant, tenants(name), users(email)')
      .order('created_at', { ascending: false })
      .limit(500);
    if (status === 'abierta' || status === 'resuelta') q = q.eq('status', status);
    const { data, error } = await q;
    if (error) return reply.code(500).send({ error: error.message });
    return reply.send({ incidents: data || [] });
  });

  // Chat de una incidencia (admin <-> cliente). Vía service_role para poder
  // acceder a cualquier empresa.
  app.get('/api/v1/admin/incidents/:id/messages', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { data, error } = await supabase
      .from('incident_messages')
      .select('id, body, user_id, created_at, users(email, name, role, is_admin)')
      .eq('incident_id', request.params.id)
      .order('created_at', { ascending: true });
    if (error) return reply.code(500).send({ error: error.message });
    return reply.send({ messages: data || [] });
  });

  app.post('/api/v1/admin/incidents/:id/messages', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const body = (request.body ?? {}).body;
    if (!body || !String(body).trim()) return reply.code(400).send({ error: 'Mensaje vacío' });
    // Recuperamos el tenant de la incidencia para guardar el mensaje.
    const { data: inc } = await supabase
      .from('incidents').select('tenant_id, status').eq('id', request.params.id).single();
    if (!inc) return reply.code(404).send({ error: 'Incidencia no encontrada' });
    const { error } = await supabase.from('incident_messages').insert({
      incident_id: request.params.id,
      tenant_id: inc.tenant_id,
      user_id: g.caller.id,
      body: String(body).trim(),
    });
    if (error) return reply.code(400).send({ error: error.message });
    return reply.send({ ok: true });
  });

  // Cambiar el estado de una incidencia (resolver / reabrir) en cualquier empresa.
  app.post('/api/v1/admin/incidents/:id/status', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const status = (request.body ?? {}).status;
    if (status !== 'abierta' && status !== 'resuelta') {
      return reply.code(400).send({ error: 'status debe ser abierta o resuelta' });
    }
    const { error } = await supabase
      .from('incidents')
      .update({ status })
      .eq('id', request.params.id);
    if (error) return reply.code(400).send({ error: error.message });
    return reply.send({ ok: true });
  });

  // Lista de administradores actuales (para gestionarlos).
  app.get('/api/v1/admin/admins', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { data, error } = await supabase
      .from('users')
      .select('id, email, name')
      .eq('is_admin', true)
      .order('email', { ascending: true });
    if (error) return reply.code(500).send({ error: error.message });
    return reply.send({ admins: data || [] });
  });

  // Nombrar (o quitar) admin a otro usuario por su correo.
  app.post('/api/v1/admin/make-admin', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { email, isAdmin } = request.body ?? {};
    if (!email) return reply.code(400).send({ error: 'Falta el correo' });
    const { data, error } = await supabase
      .from('users')
      .update({ is_admin: isAdmin === false ? false : true })
      .eq('email', String(email).trim().toLowerCase())
      .select('id, email, is_admin');
    if (error) return reply.code(400).send({ error: error.message });
    if (!data || data.length === 0) {
      return reply.code(404).send({ error: 'No hay ningún usuario con ese correo' });
    }
    return reply.send({ ok: true, user: data[0] });
  });

  // Detalle completo de una empresa: tenant + usuarios + recuentos.
  app.get('/api/v1/admin/company/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const id = request.params.id;

    const { data: tenant, error } = await supabase
      .from('tenants')
      .select('id, name, solo, subscription_status, plan_id, drivers_limit, trial_ends_at, created_at, stripe_customer_id, stripe_subscription_id, join_code')
      .eq('id', id)
      .single();
    if (error || !tenant) return reply.code(404).send({ error: 'Empresa no encontrada' });

    const { data: users } = await supabase
      .from('users')
      .select('id, email, name, username, role, active, is_admin, created_at')
      .eq('tenant_id', id)
      .order('role', { ascending: true });

    // Recuentos (head:true devuelve solo el count, sin filas).
    const countOf = async (table) => {
      const { count } = await supabase
        .from(table)
        .select('id', { count: 'exact', head: true })
        .eq('tenant_id', id);
      return count || 0;
    };
    const [vehicles, transactions, incidents] = await Promise.all([
      countOf('vehicles'),
      countOf('transactions'),
      countOf('incidents'),
    ]);

    // Resumen financiero: sumamos importes por tipo (ingreso/gasto).
    const { data: txAll } = await supabase
      .from('transactions')
      .select('amount, type')
      .eq('tenant_id', id);
    let income = 0;
    let expense = 0;
    for (const t of txAll || []) {
      const amt = Number(t.amount) || 0;
      if (t.type === 'income') income += amt;
      else expense += amt;
    }
    const summary = {
      income: Math.round(income * 100) / 100,
      expense: Math.round(expense * 100) / 100,
      balance: Math.round((income - expense) * 100) / 100,
    };

    // Transacciones recientes (con el autor) para inspección.
    const { data: recentTx } = await supabase
      .from('transactions')
      .select('id, amount, type, category, payment_method, description, created_at, users(email)')
      .eq('tenant_id', id)
      .order('created_at', { ascending: false })
      .limit(40);

    // Vehículos de la empresa.
    const { data: vehicleList } = await supabase
      .from('vehicles')
      .select('id, license_plate, model')
      .eq('tenant_id', id)
      .order('created_at', { ascending: true });

    // Incidencias de la empresa (operativas: notas conductor<->jefe).
    const { data: incidentList } = await supabase
      .from('incidents')
      .select('id, kind, body, status, created_at, users(email)')
      .eq('tenant_id', id)
      .order('created_at', { ascending: false })
      .limit(100);

    return reply.send({
      tenant,
      users: users || [],
      counts: { vehicles, transactions, incidents },
      summary,
      recent_transactions: recentTx || [],
      vehicles_list: vehicleList || [],
      incidents_list: incidentList || [],
    });
  });

  // Añadir un vehículo a una empresa (admin).
  app.post('/api/v1/admin/company/:id/vehicle', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { license_plate, model } = request.body ?? {};
    if (!license_plate || !String(license_plate).trim()) {
      return reply.code(400).send({ error: 'La matrícula es obligatoria' });
    }
    const { error } = await supabase.from('vehicles').insert({
      tenant_id: request.params.id,
      license_plate: String(license_plate).trim(),
      model: model ? String(model).trim() : null,
    });
    if (error) return reply.code(400).send({ error: error.message });
    return reply.send({ ok: true });
  });

  // Editar un vehículo (admin).
  app.patch('/api/v1/admin/vehicle/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const b = request.body ?? {};
    const patch = {};
    if (b.license_plate !== undefined) patch.license_plate = String(b.license_plate).trim();
    if (b.model !== undefined) patch.model = b.model ? String(b.model).trim() : null;
    if (Object.keys(patch).length === 0) return reply.code(400).send({ error: 'Nada que actualizar' });
    const { error } = await supabase.from('vehicles').update(patch).eq('id', request.params.id);
    if (error) return reply.code(400).send({ error: error.message });
    return reply.send({ ok: true });
  });

  // Eliminar un vehículo (admin).
  app.delete('/api/v1/admin/vehicle/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { error } = await supabase.from('vehicles').delete().eq('id', request.params.id);
    if (error) return reply.code(400).send({ error: error.message });
    return reply.send({ ok: true });
  });

  // Modificar una empresa (suscripción, plan, límite, prueba, nombre, solo).
  app.patch('/api/v1/admin/company/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const b = request.body ?? {};
    const patch = {};
    if (b.name !== undefined) patch.name = String(b.name).trim();
    if (b.subscription_status !== undefined) patch.subscription_status = b.subscription_status;
    if (b.plan_id !== undefined) patch.plan_id = b.plan_id === '' ? null : b.plan_id;
    if (b.drivers_limit !== undefined) {
      patch.drivers_limit = (b.drivers_limit === null || b.drivers_limit === '')
        ? null : Number(b.drivers_limit);
    }
    if (b.solo !== undefined) patch.solo = b.solo === true || b.solo === 'true';
    if (b.join_code !== undefined) {
      const code = String(b.join_code).trim().toUpperCase();
      patch.join_code = code === '' ? null : code;
    }
    if (b.trial_ends_at !== undefined) patch.trial_ends_at = b.trial_ends_at; // ISO o null
    // Atajo: extender la prueba N días desde ahora.
    if (b.extend_trial_days !== undefined && b.extend_trial_days !== null) {
      const days = Number(b.extend_trial_days);
      if (!Number.isNaN(days)) {
        patch.trial_ends_at = new Date(Date.now() + days * 86400000).toISOString();
      }
    }
    if (Object.keys(patch).length === 0) {
      return reply.code(400).send({ error: 'Nada que actualizar' });
    }
    const { error } = await supabase.from('tenants').update(patch).eq('id', request.params.id);
    if (error) {
      const dup = /duplicate|unique|23505/i.test(error.message || '');
      return reply.code(dup ? 409 : 400)
        .send({ error: dup ? 'Ese código de flota ya está en uso' : error.message });
    }
    return reply.send({ ok: true });
  });

  // Eliminar una empresa entera: borra el tenant (cascada a usuarios, vehículos,
  // transacciones, incidencias…) y las cuentas de auth de sus usuarios.
  app.delete('/api/v1/admin/company/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const id = request.params.id;

    const { data: users } = await supabase.from('users').select('id').eq('tenant_id', id);
    const { error } = await supabase.from('tenants').delete().eq('id', id);
    if (error) return reply.code(400).send({ error: error.message });
    // Borra las cuentas de auth (las filas de public.users ya cayeron por cascada).
    for (const u of users || []) {
      try { await supabase.auth.admin.deleteUser(u.id); } catch (_) {}
    }
    return reply.send({ ok: true, deleted_users: (users || []).length });
  });

  // Modificar un usuario de cualquier empresa (activar, rol, nombre, admin).
  app.patch('/api/v1/admin/user/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const b = request.body ?? {};
    const patch = {};
    if (b.active !== undefined) patch.active = b.active === true || b.active === 'true';
    if (b.role !== undefined && (b.role === 'owner' || b.role === 'driver')) patch.role = b.role;
    if (b.name !== undefined) patch.name = String(b.name).trim() || null;
    if (b.is_admin !== undefined) patch.is_admin = b.is_admin === true || b.is_admin === 'true';
    if (Object.keys(patch).length === 0) {
      return reply.code(400).send({ error: 'Nada que actualizar' });
    }
    const { error } = await supabase.from('users').update(patch).eq('id', request.params.id);
    if (error) return reply.code(400).send({ error: error.message });
    return reply.send({ ok: true });
  });

  // Eliminar un usuario (su perfil + su cuenta de auth).
  app.delete('/api/v1/admin/user/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const id = request.params.id;
    await supabase.from('users').delete().eq('id', id);
    try {
      await supabase.auth.admin.deleteUser(id);
    } catch (e) {
      if (!/not.*found|404/i.test(e?.message || '')) {
        return reply.code(400).send({ error: `No se pudo eliminar la cuenta: ${e.message}` });
      }
    }
    return reply.send({ ok: true });
  });

  // Vehículos asignados a un conductor (admin): lista de vehicle_id.
  app.get('/api/v1/admin/user/:id/vehicles', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { data, error } = await supabase
      .from('driver_vehicles').select('vehicle_id').eq('user_id', request.params.id);
    if (error) return reply.code(500).send({ error: error.message });
    return reply.send({ vehicleIds: (data || []).map((r) => r.vehicle_id) });
  });

  // Asignar qué vehículos usa un conductor (admin). Reemplaza el conjunto.
  app.post('/api/v1/admin/user/:id/vehicles', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const userId = request.params.id;
    const vehicleIds = Array.isArray((request.body ?? {}).vehicleIds) ? request.body.vehicleIds : [];
    // tenant del conductor (para las filas de driver_vehicles).
    const { data: u } = await supabase.from('users').select('tenant_id').eq('id', userId).single();
    if (!u?.tenant_id) return reply.code(404).send({ error: 'Conductor no encontrado' });
    await supabase.from('driver_vehicles').delete().eq('user_id', userId);
    if (vehicleIds.length > 0) {
      const rows = vehicleIds.map((vid) => ({ tenant_id: u.tenant_id, user_id: userId, vehicle_id: vid }));
      const { error } = await supabase.from('driver_vehicles').insert(rows);
      if (error) return reply.code(400).send({ error: error.message });
    }
    return reply.send({ ok: true });
  });

  // --- Notificación push de una incidencia / mensaje (FCM) ---
  // La app lo llama tras crear una incidencia o un mensaje de chat. Si push no
  // está configurado (sin FCM_SERVICE_ACCOUNT), responde ok sin hacer nada.
  app.post('/api/v1/notify-incident', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (!pushEnabled()) return reply.send({ ok: true, push: false });

    const { incidentId, kind, body } = request.body ?? {};
    if (!incidentId) return reply.code(400).send({ error: 'incidentId es obligatorio' });

    const { data: inc } = await supabase
      .from('incidents')
      .select('id, tenant_id, user_id, body')
      .eq('id', incidentId)
      .single();
    if (!inc || inc.tenant_id !== caller.tenant_id) {
      return reply.code(404).send({ error: 'Incidencia no encontrada' });
    }

    // Destinatarios: si escribe el conductor -> los owners; si escribe el owner
    // -> el autor (conductor). Nunca te notificas a ti mismo.
    let recipientIds;
    if (caller.role === 'owner') {
      recipientIds = [inc.user_id];
    } else {
      const { data: owners } = await supabase
        .from('users')
        .select('id')
        .eq('tenant_id', inc.tenant_id)
        .eq('role', 'owner');
      recipientIds = (owners || []).map((o) => o.id);
    }
    recipientIds = recipientIds.filter((id) => id && id !== caller.id);
    if (recipientIds.length === 0) return reply.send({ ok: true, push: true, sent: 0 });

    const { data: toks } = await supabase
      .from('device_tokens')
      .select('token')
      .in('user_id', recipientIds);
    const tokens = (toks || []).map((t) => t.token);

    const title = kind === 'new_message' ? 'Nuevo mensaje de incidencia' : 'Nueva incidencia';
    const text = (body || inc.body || '').toString().slice(0, 140);
    const result = await sendToTokens(
      tokens,
      { title, body: text, data: { type: 'incident', incidentId: inc.id } },
      request.log,
    );

    if (result.invalidTokens.length > 0) {
      await supabase.from('device_tokens').delete().in('token', result.invalidTokens);
    }
    return reply.send({ ok: true, push: true, sent: result.sent });
  });

  // --- Stripe Checkout (Fase 4) ---
  app.post('/api/v1/create-checkout-session', async (request, reply) => {
    if (!stripe) return reply.code(500).send({ error: 'Stripe no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (caller.role !== 'owner') return reply.code(403).send({ error: 'Solo un Owner puede contratar un plan' });

    const { priceId } = request.body ?? {};
    if (!priceId) return reply.code(400).send({ error: 'priceId es obligatorio' });
    const plan = planForPrice(priceId);
    if (!plan) return reply.code(400).send({ error: 'priceId desconocido' });

    const { data: tenant } = await supabase
      .from('tenants')
      .select('stripe_customer_id')
      .eq('id', caller.tenant_id)
      .single();

    const metadata = {
      tenant_id: caller.tenant_id,
      plan_id: plan.plan_id,
      drivers_limit: plan.drivers_limit === null ? 'null' : String(plan.drivers_limit),
    };

    try {
      const session = await stripe.checkout.sessions.create({
        mode: 'subscription',
        line_items: [{ price: priceId, quantity: 1 }],
        success_url: STRIPE_SUCCESS_URL,
        cancel_url: STRIPE_CANCEL_URL,
        ...(tenant?.stripe_customer_id ? { customer: tenant.stripe_customer_id } : {}),
        metadata,
        subscription_data: { metadata },
        client_reference_id: caller.tenant_id,
      });
      return reply.send({ url: session.url, id: session.id });
    } catch (e) {
      request.log.error(e);
      return reply.code(502).send({ error: 'No se pudo crear la sesión de Checkout', detail: e.message });
    }
  });

  // --- Stripe Customer Portal (Fase 4) ---
  app.post('/api/v1/create-portal-session', async (request, reply) => {
    if (!stripe) return reply.code(500).send({ error: 'Stripe no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (caller.role !== 'owner') return reply.code(403).send({ error: 'Solo un Owner puede gestionar la facturación' });

    const { data: tenant } = await supabase
      .from('tenants')
      .select('stripe_customer_id')
      .eq('id', caller.tenant_id)
      .single();
    if (!tenant?.stripe_customer_id) {
      return reply.code(400).send({ error: 'No hay cliente de Stripe asociado (contrata un plan primero)' });
    }

    try {
      const session = await stripe.billingPortal.sessions.create({
        customer: tenant.stripe_customer_id,
        return_url: STRIPE_SUCCESS_URL,
      });
      return reply.send({ url: session.url });
    } catch (e) {
      request.log.error(e);
      return reply.code(502).send({ error: 'No se pudo crear la sesión del portal', detail: e.message });
    }
  });

  // ============================================================
  // Retos / metas por conductor (km_100k, money_100k, days_300), ESCALONADOS.
  // Solo los empresarios (owner) ven el progreso de SUS conductores. Cada reto
  // tiene niveles: el nivel 1 pide la base (100.000 km / 100.000 € / 300 días);
  // a partir del nivel 2, el DOBLE (200.000 / 200.000 / 600), y se repite. Es
  // INCREMENTAL: el progreso se mide desde el valor que tenía la métrica al
  // empezar el tramo (baseline). El siguiente nivel NO se ve hasta que la
  // administración aprueba el actual. Premio NO automático (lo aprueba el admin).
  // Anti-fraude: días activos < 300 -> sospechoso; max_jump grande -> km inflado.
  // ============================================================
  const CHALLENGE_BASE = { km_100k: 100000, money_100k: 100000, days_300: 300 };
  const CHALLENGE_MIN_DAYS = 300;     // mínimo de días para validar km/€
  const CHALLENGE_MAX_JUMP = 2000;    // salto de km de golpe por encima -> sospechoso
  const CHALLENGE_MAX_INCOME = 1500;  // una carrera por encima de 1500 € -> sospechoso

  // Objetivo (incremento) de un reto en un nivel dado. Ciclo de 4 niveles: el
  // 1º de cada ciclo (niveles 1, 5, 9, 13...) vuelve a la base; los otros tres,
  // el doble. Así de vez en cuando "baja" como sorpresa.
  const incrementFor = (challenge, level) =>
    CHALLENGE_BASE[challenge] * (((level - 1) % 4) === 0 ? 1 : 2);

  // A partir de los claims de un conductor+reto, calcula el nivel actual, el
  // baseline (métrica al empezar el tramo) y si hay un claim pendiente/rechazado.
  function levelState(claims) {
    let maxRewarded = 0;
    let baselineForNext = 0;
    for (const c of claims) {
      if (c.status === 'rewarded' && c.level > maxRewarded) {
        maxRewarded = c.level;
        baselineForNext = Number(c.metric_value ?? 0);
      }
    }
    const level = maxRewarded + 1;
    const baseline = maxRewarded > 0 ? baselineForNext : 0;
    const atCurrent = claims.find((c) => c.level === level);
    return { level, baseline, pending: atCurrent?.status === 'pending', rejected: atCurrent?.status === 'rejected' };
  }

  // Progreso de los retos de TODOS los conductores de la empresa (solo owner).
  app.get('/api/v1/challenges/company', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (caller.role !== 'owner') {
      return reply.code(403).send({ error: 'Solo el propietario ve los retos' });
    }
    try {
      const { data: stats, error } = await supabase.rpc('challenge_stats_tenant', { p_tenant: caller.tenant_id });
      if (error) throw new Error(error.message);

      // Todos los claims de la empresa, agrupados por conductor+reto.
      const { data: allClaims } = await supabase
        .from('challenge_claims')
        .select('user_id, challenge, level, metric_value, status')
        .eq('tenant_id', caller.tenant_id);
      const byUserChal = {};
      for (const c of allClaims ?? []) {
        ((byUserChal[c.user_id] ??= {})[c.challenge] ??= []).push(c);
      }

      const drivers = [];
      for (const r of stats ?? []) {
        const metrics = {
          km_100k: Number(r.km ?? 0),
          money_100k: Number(r.money ?? 0),
          days_300: Number(r.active_days ?? 0),
        };
        const activeDays = Number(r.active_days ?? 0);
        const maxJump = Number(r.max_jump ?? 0);
        const maxIncome = Number(r.max_income ?? 0);
        const challenges = [];
        for (const type of Object.keys(CHALLENGE_BASE)) {
          const claims = (byUserChal[r.user_id]?.[type]) ?? [];
          const st = levelState(claims);
          const target = incrementFor(type, st.level);
          const metric = metrics[type];
          const progress = Math.max(0, metric - st.baseline);
          const reached = progress >= target;
          // Crea el aviso al admin al alcanzar el tramo (si no hay claim ya).
          if (reached && !st.pending && !st.rejected) {
            const { error: insErr } = await supabase.from('challenge_claims').insert({
              tenant_id: caller.tenant_id, user_id: r.user_id, challenge: type,
              level: st.level, baseline: st.baseline, target,
              metric_value: metric, active_days: activeDays,
            });
            if (insErr && !/duplicate|unique|23505/i.test(insErr.message || '')) {
              app.log.warn(`[challenge] no se pudo crear claim: ${insErr.message}`);
            } else if (!insErr) {
              st.pending = true;
            }
          }
          challenges.push({
            type, level: st.level, target, progress,
            remaining: Math.max(0, target - progress),
            pct: target > 0 ? Math.min(1, progress / target) : 0,
            reached, pending: st.pending, rejected: st.rejected,
          });
        }
        drivers.push({
          user_id: r.user_id, name: r.name, email: r.email,
          max_jump: maxJump, max_income: maxIncome,
          // El empresario ve aviso si hay un posible km o dinero manipulado
          // (salto grande). Lo de "< 300 días" es señal interna para el admin.
          km_suspicious: maxJump > CHALLENGE_MAX_JUMP,
          money_suspicious: maxIncome > CHALLENGE_MAX_INCOME,
          challenges,
        });
      }
      return reply.send({ drivers });
    } catch (e) {
      request.log.error(e);
      return reply.code(500).send({ error: 'No se pudieron calcular los retos', detail: e.message });
    }
  });

  // Admin: lista de retos logrados pendientes de revisar (de todas las empresas).
  app.get('/api/v1/admin/challenges', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { data, error } = await supabase
      .from('challenge_claims')
      .select('id, challenge, level, target, baseline, metric_value, active_days, status, created_at, '
        + 'users:user_id(email, name), tenants:tenant_id(name)')
      .order('created_at', { ascending: false });
    if (error) return reply.code(500).send({ error: error.message });
    // Sospechoso si el reto de km/€ se logró con menos del mínimo de días.
    const rows = (data ?? []).map((r) => ({
      ...r,
      suspicious: r.challenge !== 'days_300' && (r.active_days ?? 0) < CHALLENGE_MIN_DAYS,
    }));
    return reply.send({ claims: rows });
  });

  // Admin: aprobar (mes gratis al dueño de la suscripción) o rechazar un reto.
  // Al aprobar, el conductor sube de nivel automáticamente (se deriva de los
  // claims 'rewarded'), y solo entonces ve el siguiente reto (más grande).
  app.post('/api/v1/admin/challenges/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const action = (request.body ?? {}).action;
    if (action !== 'reward' && action !== 'reject') {
      return reply.code(400).send({ error: 'Acción no válida' });
    }
    const { data: claim, error: cErr } = await supabase
      .from('challenge_claims').select('id, tenant_id, status').eq('id', request.params.id).maybeSingle();
    if (cErr || !claim) return reply.code(404).send({ error: 'Reto no encontrado' });

    if (action === 'reward') {
      // Un mes gratis: extiende trial_ends_at +30 días sobre el final actual.
      const { data: t } = await supabase
        .from('tenants').select('trial_ends_at').eq('id', claim.tenant_id).maybeSingle();
      const now = Date.now();
      const cur = t?.trial_ends_at ? new Date(t.trial_ends_at).getTime() : 0;
      const base = cur > now ? cur : now;
      await supabase.from('tenants')
        .update({ trial_ends_at: new Date(base + 30 * 86400000).toISOString() })
        .eq('id', claim.tenant_id);
    }
    await supabase.from('challenge_claims')
      .update({ status: action === 'reward' ? 'rewarded' : 'rejected', reviewed_at: new Date().toISOString() })
      .eq('id', claim.id);
    return reply.send({ ok: true });
  });

  // ============================================================
  // Programa de referidos "Invita y Gana" (v2, por hitos) — Iteración 2.
  // Endpoints de lectura/compartición/validación. La validación de pagos y los
  // hitos van por el webhook de Stripe (Iteración 3). Premio = días gratis al
  // TENANT (empresa). Solo invitan owners/autónomos con suscripción activa.
  // ============================================================

  // Lee toda la config de referidos (system_config) como objeto clave→valor.
  async function refConfig() {
    const { data } = await supabase.from('system_config').select('key, value');
    const m = {};
    for (const r of data ?? []) m[r.key] = r.value;
    return m;
  }

  // Definición de hitos a partir de la config: [{level, required, days}].
  function milestonesFrom(cfg) {
    const out = [];
    for (let lvl = 1; lvl <= 5; lvl++) {
      const required = parseInt(cfg[`referral_milestone_${lvl}_required`] ?? '0', 10);
      const days = parseInt(cfg[`referral_milestone_${lvl}_days`] ?? '0', 10);
      if (required > 0) out.push({ level: lvl, required, days });
    }
    return out;
  }

  // ¿Puede invitar? Owner/autónomo con suscripción ACTIVA de pago (no en prueba).
  async function isReferralEligible(caller) {
    if (!caller || caller.role !== 'owner' || !caller.tenant_id) return false;
    const { data: t } = await supabase
      .from('tenants').select('subscription_status').eq('id', caller.tenant_id).maybeSingle();
    return t?.subscription_status === 'active';
  }

  // Devuelve el código del usuario; si no tiene, genera uno único "TX"+6.
  async function ensureReferralCode(userId) {
    const { data: existing } = await supabase
      .from('referral_codes').select('code').eq('user_id', userId).maybeSingle();
    if (existing) return existing.code;
    const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    for (let i = 0; i < 6; i++) {
      const code = 'TX' + Array.from({ length: 6 },
        () => ALPHABET[Math.floor(Math.random() * ALPHABET.length)]).join('');
      const { error } = await supabase.from('referral_codes').insert({ user_id: userId, code });
      if (!error) return code;
      if (!/duplicate|unique|23505/i.test(error.message || '')) throw new Error(error.message);
      // 23505 en (user_id) = otro proceso lo creó: devuélvelo
      const { data: again } = await supabase
        .from('referral_codes').select('code').eq('user_id', userId).maybeSingle();
      if (again) return again.code;
    }
    throw new Error('No se pudo generar el código de referido');
  }

  // --- Anti-fraude de referidos (Iteración 4) -----------------------------
  // Dominios de email desechables más habituales (ampliable por config).
  const DISPOSABLE_EMAIL_DOMAINS = [
    'mailinator.com', 'tempmail.com', '10minutemail.com', 'guerrillamail.com',
    'yopmail.com', 'trashmail.com', 'sharklasers.com', 'getnada.com',
    'temp-mail.org', 'dispostable.com', 'maildrop.cc', 'fakeinbox.com',
  ];

  // Crea una alerta, evitando duplicar una abierta del mismo tipo/referral.
  async function createFraudAlert(referralId, type, severity, detail) {
    const { data: ex } = await supabase.from('referral_fraud_alerts')
      .select('id').eq('referral_id', referralId).eq('type', type).eq('status', 'open').maybeSingle();
    if (ex) return;
    await supabase.from('referral_fraud_alerts')
      .insert({ referral_id: referralId, type, severity, detail });
  }

  // Comprobaciones en tiempo real al validar un código. NO bloquea: solo avisa.
  async function runFraudChecks({ referralId, referrerUserId, referredUserId, ip, deviceId }) {
    const cfg = await refConfig();
    const { data: ru } = await supabase.from('users').select('email').eq('id', referredUserId).maybeSingle();
    const email = (ru?.email || '').toLowerCase();
    const domain = email.split('@')[1] || '';

    // 1) Auto-referido por email (mismo correo que el referidor).
    const { data: rr } = await supabase.from('users').select('email').eq('id', referrerUserId).maybeSingle();
    if (email && rr?.email && email === rr.email.toLowerCase()) {
      await createFraudAlert(referralId, 'self_referral', 'high', { email });
    }

    // 2) Email temporal/desechable (lista + dominios bloqueados por config).
    const blocked = (cfg.referral_email_domains_blocked || '')
      .split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
    if (domain && (blocked.includes(domain) || DISPOSABLE_EMAIL_DOMAINS.includes(domain))) {
      await createFraudAlert(referralId, 'temp_email', 'medium', { domain });
    }

    // 3) Misma IP que otro referido (aviso, no bloqueo).
    if (ip) {
      const { data: sameIp } = await supabase.from('referrals')
        .select('id').eq('signup_ip', ip).neq('id', referralId).limit(1);
      if ((sameIp ?? []).length) await createFraudAlert(referralId, 'same_ip', 'low', { ip });

      // 4) Ráfaga de IP: más de N referidos desde la misma IP en 24h.
      const maxIp = parseInt(cfg.referral_max_per_ip_24h ?? '3', 10);
      const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
      const { count } = await supabase.from('referrals')
        .select('id', { count: 'exact', head: true }).eq('signup_ip', ip).gte('created_at', since);
      if ((count ?? 0) > maxIp) await createFraudAlert(referralId, 'ip_burst', 'high', { ip, count });
    }

    // 5) Dispositivo duplicado.
    if (deviceId) {
      const { data: sameDev } = await supabase.from('referrals')
        .select('id').eq('signup_device_id', deviceId).neq('id', referralId).limit(1);
      if ((sameDev ?? []).length) await createFraudAlert(referralId, 'device_dup', 'medium', { deviceId });
    }
  }

  // GET código del referidor + elegibilidad + definición de hitos.
  app.get('/api/v1/referrals/code', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    try {
      const cfg = await refConfig();
      if (cfg.referral_enabled !== 'true') return reply.send({ enabled: false });
      const eligible = await isReferralEligible(caller);
      const code = eligible ? await ensureReferralCode(caller.id) : null;
      return reply.send({
        enabled: true, eligible, code,
        milestones: milestonesFrom(cfg),
        annual_max_days: parseInt(cfg.referral_annual_max_days ?? '360', 10),
        validation_days: parseInt(cfg.referral_validation_days ?? '30', 10),
      });
    } catch (e) {
      request.log.error(e);
      return reply.code(500).send({ error: 'No se pudo obtener el código', detail: e.message });
    }
  });

  // POST registrar una compartición (límite diario) y devolver el código.
  app.post('/api/v1/referrals/share', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (!await isReferralEligible(caller)) {
      return reply.code(403).send({ error: 'Necesitas una suscripción activa para invitar' });
    }
    const channel = String((request.body ?? {}).channel ?? 'link');
    if (!['whatsapp', 'email', 'sms', 'link', 'other'].includes(channel)) {
      return reply.code(400).send({ error: 'Canal no válido' });
    }
    const cfg = await refConfig();
    const maxPerDay = parseInt(cfg.referral_max_shares_per_day ?? '20', 10);
    const since = new Date(); since.setHours(0, 0, 0, 0);
    const { count } = await supabase.from('referral_shares')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', caller.id).gte('created_at', since.toISOString());
    if ((count ?? 0) >= maxPerDay) {
      return reply.code(429).send({ error: `Límite de ${maxPerDay} invitaciones por día` });
    }
    const code = await ensureReferralCode(caller.id);
    await supabase.from('referral_shares').insert({ user_id: caller.id, code, channel });
    return reply.send({ ok: true, code, shares_today: (count ?? 0) + 1 });
  });

  // POST aplicar un código (el referido lo introduce tras crear su empresa).
  app.post('/api/v1/referrals/validate', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (!caller.tenant_id) return reply.code(400).send({ error: 'Crea tu empresa primero' });
    const code = String((request.body ?? {}).code ?? '').trim();
    if (!code) return reply.code(400).send({ error: 'Falta el código' });

    const { data: prev } = await supabase.from('referrals')
      .select('id').eq('referred_user_id', caller.id).maybeSingle();
    if (prev) return reply.code(409).send({ error: 'Ya has usado un código de invitación' });

    const { data: rc } = await supabase.from('referral_codes')
      .select('user_id, is_active').ilike('code', code).maybeSingle();
    if (!rc || rc.is_active === false) return reply.code(404).send({ error: 'Código no válido' });
    if (rc.user_id === caller.id) return reply.code(400).send({ error: 'No puedes invitarte a ti mismo' });

    const ip = (request.headers['x-forwarded-for'] || request.ip || '').toString().split(',')[0].trim();
    const device = String((request.body ?? {}).device_id ?? '');
    const { data: inserted, error } = await supabase.from('referrals').insert({
      referrer_user_id: rc.user_id, referred_user_id: caller.id,
      referred_tenant_id: caller.tenant_id, status: 'pending',
      signup_ip: ip || null, signup_device_id: device || null,
    }).select('id').single();
    if (error) {
      const dup = /duplicate|unique|23505/i.test(error.message || '');
      return reply.code(dup ? 409 : 400).send({ error: dup ? 'Ya has usado un código' : error.message });
    }
    // Anti-fraude (no bloquea: solo crea alertas para que el admin revise).
    try {
      await runFraudChecks({
        referralId: inserted.id, referrerUserId: rc.user_id, referredUserId: caller.id,
        ip, deviceId: device,
      });
    } catch (e) {
      request.log.error(`[referral-fraud] ${e.message}`);
    }
    return reply.send({ ok: true });
  });

  // GET historial de referidos del referidor.
  app.get('/api/v1/referrals/history', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    const { data, error } = await supabase.from('referrals')
      .select('id, status, created_at, validated_at, reverted_at, users:referred_user_id(email, name)')
      .eq('referrer_user_id', caller.id).order('created_at', { ascending: false });
    if (error) return reply.code(500).send({ error: error.message });
    return reply.send({ referrals: data ?? [] });
  });

  // GET progreso de hitos del referidor.
  app.get('/api/v1/referrals/progress', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    const cfg = await refConfig();
    const milestones = milestonesFrom(cfg);
    const { count } = await supabase.from('referrals')
      .select('id', { count: 'exact', head: true })
      .eq('referrer_user_id', caller.id).eq('status', 'valid');
    const valid = count ?? 0;
    const { data: claimed } = await supabase.from('referral_milestone_rewards')
      .select('milestone_level').eq('user_id', caller.id);
    const claimedLevels = new Set((claimed ?? []).map((c) => c.milestone_level));
    const { data: u } = await supabase.from('users')
      .select('referral_rewards_annual_days').eq('id', caller.id).maybeSingle();
    const next = milestones.find((m) => valid < m.required) ?? null;
    return reply.send({
      valid_referrals: valid,
      milestones: milestones.map((m) => ({ ...m, reached: valid >= m.required, claimed: claimedLevels.has(m.level) })),
      next: next ? { ...next, remaining: next.required - valid } : null,
      annual_days: u?.referral_rewards_annual_days ?? 0,
      annual_max: parseInt(cfg.referral_annual_max_days ?? '360', 10),
    });
  });

  // ============================================================
  // Referidos v2 — Iteración 5: panel de administración.
  // Listado con filtros, KPIs (conversión, CPA, K-factor), gestión de alertas,
  // edición de la config y escaneo anti-fraude bajo demanda. Solo admin.
  // ============================================================

  // Listado de referidos (filtros: status). Incluye correos y alertas abiertas.
  app.get('/api/v1/admin/referrals', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const status = request.query?.status;
    let q = supabase.from('referrals')
      .select('id, status, created_at, validated_at, reverted_at, signup_ip, signup_device_id, '
        + 'referrer:referrer_user_id(email, name), referred:referred_user_id(email, name)')
      .order('created_at', { ascending: false }).limit(500);
    if (['pending', 'valid', 'reverted', 'rejected'].includes(status)) q = q.eq('status', status);
    const { data: refs, error } = await q;
    if (error) return reply.code(500).send({ error: error.message });
    // Alertas abiertas, agrupadas por referral.
    const { data: alerts } = await supabase.from('referral_fraud_alerts')
      .select('id, referral_id, type, severity, status, created_at, detail')
      .eq('status', 'open');
    const byRef = {};
    for (const a of alerts ?? []) (byRef[a.referral_id] ??= []).push(a);
    const rows = (refs ?? []).map((r) => ({ ...r, alerts: byRef[r.id] ?? [] }));
    return reply.send({ referrals: rows, open_alerts: (alerts ?? []).length });
  });

  // KPIs del programa: conversión, CPA (días/adquisición), K-factor.
  app.get('/api/v1/admin/referrals/kpis', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const countWhere = async (col, val) => {
      const { count } = await supabase.from('referrals')
        .select('id', { count: 'exact', head: true }).eq(col, val);
      return count ?? 0;
    };
    const [pending, valid, reverted, rejected] = await Promise.all([
      countWhere('status', 'pending'), countWhere('status', 'valid'),
      countWhere('status', 'reverted'), countWhere('status', 'rejected'),
    ]);
    const total = pending + valid + reverted + rejected;
    const { count: sharesTotal } = await supabase.from('referral_shares')
      .select('id', { count: 'exact', head: true });
    // Distintos referidores con al menos un válido + total de días concedidos.
    const { data: validRows } = await supabase.from('referrals')
      .select('referrer_user_id').eq('status', 'valid').limit(5000);
    const distinctReferrers = new Set((validRows ?? []).map((r) => r.referrer_user_id)).size;
    const { data: rewardRows } = await supabase.from('referral_milestone_rewards')
      .select('days_awarded').limit(5000);
    const daysAwarded = (rewardRows ?? []).reduce((s, r) => s + (r.days_awarded ?? 0), 0);
    const { count: openAlerts } = await supabase.from('referral_fraud_alerts')
      .select('id', { count: 'exact', head: true }).eq('status', 'open');
    return reply.send({
      total, pending, valid, reverted, rejected,
      shares_total: sharesTotal ?? 0,
      conversion_rate: total ? +(valid / total).toFixed(3) : 0,        // válidos / total
      cpa_days: valid ? +(daysAwarded / valid).toFixed(1) : 0,         // días gratis por adquisición
      k_factor: distinctReferrers ? +(valid / distinctReferrers).toFixed(2) : 0, // válidos por referidor
      days_awarded: daysAwarded,
      open_alerts: openAlerts ?? 0,
    });
  });

  // Gestionar una alerta de fraude: resolver o descartar.
  app.post('/api/v1/admin/referrals/resolve/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const action = (request.body ?? {}).action;
    if (action !== 'resolve' && action !== 'dismiss') {
      return reply.code(400).send({ error: 'Acción no válida' });
    }
    const { error } = await supabase.from('referral_fraud_alerts')
      .update({ status: action === 'resolve' ? 'resolved' : 'dismissed', resolved_at: new Date().toISOString() })
      .eq('id', request.params.id);
    if (error) return reply.code(500).send({ error: error.message });
    return reply.send({ ok: true });
  });

  // Editar la configuración del programa (solo claves referral_*).
  app.put('/api/v1/admin/referrals/config', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const body = request.body ?? {};
    const updates = Object.entries(body).filter(([k]) => k.startsWith('referral_'));
    if (!updates.length) return reply.code(400).send({ error: 'Nada que actualizar (claves referral_*)' });
    for (const [key, value] of updates) {
      await supabase.from('system_config')
        .upsert({ key, value: String(value), updated_at: new Date().toISOString() }, { onConflict: 'key' });
    }
    return reply.send({ ok: true, updated: updates.map(([k]) => k) });
  });

  // Escaneo anti-fraude bajo demanda (batch): ráfagas de IP y dispositivos
  // duplicados en las últimas 24h que aún no tengan alerta.
  app.post('/api/v1/admin/referrals/scan', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const cfg = await refConfig();
    const maxIp = parseInt(cfg.referral_max_per_ip_24h ?? '3', 10);
    const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
    const { data: recent } = await supabase.from('referrals')
      .select('id, signup_ip, signup_device_id, created_at').gte('created_at', since).limit(5000);
    const byIp = {};
    const byDev = {};
    for (const r of recent ?? []) {
      if (r.signup_ip) (byIp[r.signup_ip] ??= []).push(r.id);
      if (r.signup_device_id) (byDev[r.signup_device_id] ??= []).push(r.id);
    }
    let created = 0;
    for (const [ip, ids] of Object.entries(byIp)) {
      if (ids.length > maxIp) {
        for (const id of ids) { await createFraudAlert(id, 'ip_burst', 'high', { ip, count: ids.length }); created++; }
      }
    }
    for (const [dev, ids] of Object.entries(byDev)) {
      if (ids.length > 1) {
        for (const id of ids) { await createFraudAlert(id, 'device_dup', 'medium', { deviceId: dev }); created++; }
      }
    }
    return reply.send({ ok: true, scanned: (recent ?? []).length, alerts_created_or_kept: created });
  });

  // ============================================================
  // Referidos v2 — Iteración 3: validación, hitos y reversión.
  // Premio = días gratis al TENANT del referidor (extiende trial_ends_at), con
  // tope anual configurable. Idempotente: recalcula hitos desde el nº de
  // referidos VÁLIDOS, concediendo los que falten y revocando los que ya no
  // correspondan (p. ej. tras una reversión por cancelación temprana).
  // ============================================================

  // Suma (o resta, si delta<0) días al trial_ends_at del tenant del referidor.
  async function extendReferrerTrial(referrerUserId, deltaDays) {
    if (!deltaDays) return;
    const { data: u } = await supabase.from('users').select('tenant_id').eq('id', referrerUserId).maybeSingle();
    if (!u?.tenant_id) return;
    const { data: t } = await supabase.from('tenants').select('trial_ends_at').eq('id', u.tenant_id).maybeSingle();
    const now = Date.now();
    const cur = t?.trial_ends_at ? new Date(t.trial_ends_at).getTime() : now;
    const base = cur > now ? cur : now; // si está en el pasado, desde hoy
    await supabase.from('tenants')
      .update({ trial_ends_at: new Date(base + deltaDays * 86400000).toISOString() })
      .eq('id', u.tenant_id);
  }

  // Envía una notificación push a un usuario (busca sus tokens en device_tokens).
  async function notifyUser(userId, title, body, data = {}) {
    if (!userId || !pushEnabled()) return;
    const { data: toks } = await supabase.from('device_tokens').select('token').eq('user_id', userId);
    const tokens = (toks || []).map((t) => t.token);
    if (!tokens.length) return;
    const result = await sendToTokens(tokens, { title, body, data }, app.log);
    if (result.invalidTokens.length) {
      await supabase.from('device_tokens').delete().in('token', result.invalidTokens);
    }
  }

  // Recalcula los hitos del referidor: concede los nuevos y revoca los que ya no
  // correspondan, respetando el tope anual de días.
  async function recomputeReferrerMilestones(referrerUserId) {
    if (!referrerUserId) return;
    const cfg = await refConfig();
    const milestones = milestonesFrom(cfg);
    const annualMax = parseInt(cfg.referral_annual_max_days ?? '360', 10);
    const year = new Date().getFullYear();

    const { count } = await supabase.from('referrals')
      .select('id', { count: 'exact', head: true })
      .eq('referrer_user_id', referrerUserId).eq('status', 'valid');
    const valid = count ?? 0;

    const { data: u } = await supabase.from('users')
      .select('referral_rewards_annual_days, referral_annual_year').eq('id', referrerUserId).maybeSingle();
    let annualDays = (u?.referral_annual_year === year) ? (u?.referral_rewards_annual_days ?? 0) : 0;

    const { data: claimedRows } = await supabase.from('referral_milestone_rewards')
      .select('id, milestone_level, days_awarded').eq('user_id', referrerUserId);
    const claimed = new Map((claimedRows ?? []).map((r) => [r.milestone_level, r]));
    const target = new Set(milestones.filter((m) => valid >= m.required).map((m) => m.level));

    // Conceder hitos alcanzados que aún no se hayan concedido.
    for (const m of milestones) {
      if (target.has(m.level) && !claimed.has(m.level)) {
        const remaining = Math.max(0, annualMax - annualDays);
        const award = Math.min(m.days, remaining);
        await supabase.from('referral_milestone_rewards').insert({
          user_id: referrerUserId, milestone_level: m.level, required: m.required, days_awarded: award,
        });
        if (award > 0) {
          await extendReferrerTrial(referrerUserId, award);
          annualDays += award;
          await notifyUser(referrerUserId, '🎉 ¡Has ganado días gratis!',
            `Hito ${m.level} conseguido: +${award} días de suscripción gratis. ¡Sigue invitando!`,
            { type: 'referral_milestone', level: m.level });
        }
        app.log.info(`[referral] hito ${m.level} concedido a ${referrerUserId} (+${award} días)`);
      }
    }
    // Revocar hitos que ya no correspondan (tras una reversión).
    for (const [lvl, row] of claimed) {
      if (!target.has(lvl)) {
        if ((row.days_awarded ?? 0) > 0) { await extendReferrerTrial(referrerUserId, -row.days_awarded); annualDays -= row.days_awarded; }
        await supabase.from('referral_milestone_rewards').delete().eq('id', row.id);
        app.log.info(`[referral] hito ${lvl} revocado a ${referrerUserId}`);
      }
    }
    if (annualDays < 0) annualDays = 0;
    const lastLevel = target.size ? Math.max(...target) : 0;
    await supabase.from('users').update({
      referral_total_valid: valid,
      referral_last_milestone_reached: lastLevel,
      referral_rewards_annual_days: annualDays,
      referral_annual_year: year,
    }).eq('id', referrerUserId);
  }

  // El referido PAGA -> su referral pasa a 'valid' (si está dentro de plazo) y se
  // recalculan los hitos del referidor.
  async function validateReferralForTenant(tenantId) {
    if (!tenantId) return;
    const cfg = await refConfig();
    const validationDays = parseInt(cfg.referral_validation_days ?? '30', 10);
    const { data: ref } = await supabase.from('referrals')
      .select('id, referrer_user_id, created_at, status').eq('referred_tenant_id', tenantId).maybeSingle();
    if (!ref || ref.status !== 'pending') return;
    const ageDays = (Date.now() - new Date(ref.created_at).getTime()) / 86400000;
    if (ageDays > validationDays) {
      await supabase.from('referrals').update({ status: 'rejected' }).eq('id', ref.id);
      return;
    }
    await supabase.from('referrals')
      .update({ status: 'valid', validated_at: new Date().toISOString() }).eq('id', ref.id);
    await notifyUser(ref.referrer_user_id, '🎉 ¡Tu invitado se ha suscrito!',
      'Una empresa que invitaste ya es cliente. Revisa tus retos: puede que hayas ganado días gratis.',
      { type: 'referral_valid' });
    await recomputeReferrerMilestones(ref.referrer_user_id);
  }

  // El referido CANCELA dentro del periodo de gracia -> su referral se revierte
  // y se recalculan (revocan) los hitos del referidor.
  async function revertReferralForTenant(tenantId) {
    if (!tenantId) return;
    const cfg = await refConfig();
    const grace = parseInt(cfg.referral_cancellation_grace_days ?? '15', 10);
    const { data: ref } = await supabase.from('referrals')
      .select('id, referrer_user_id, validated_at, status').eq('referred_tenant_id', tenantId).maybeSingle();
    if (!ref || ref.status !== 'valid') return;
    if (ref.validated_at) {
      const ageDays = (Date.now() - new Date(ref.validated_at).getTime()) / 86400000;
      if (ageDays > grace) return; // fuera del periodo de gracia: no se revierte
    }
    await supabase.from('referrals')
      .update({ status: 'reverted', reverted_at: new Date().toISOString() }).eq('id', ref.id);
    await recomputeReferrerMilestones(ref.referrer_user_id);
  }

  app.post('/webhooks/stripe', async (request, reply) => {
    if (!stripe) return reply.code(500).send({ error: 'Stripe no configurado' });
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });

    const sig = request.headers['stripe-signature'];
    let event;
    try {
      event = stripe.webhooks.constructEvent(request.rawBody, sig, STRIPE_WEBHOOK_SECRET);
    } catch (e) {
      return reply.code(400).send({ error: `Firma de webhook inválida: ${e.message}` });
    }

    try {
      const result = await applyStripeEvent(supabase, event);
      app.log.info(`[stripe-webhook] ${result.type} handled=${result.handled} tenant=${result.tenant_id ?? '-'}`);
      // Programa de referidos: validar al pagar / revertir al cancelar.
      if (result.handled && result.tenant_id) {
        try {
          if (result.type === 'checkout.session.completed' || result.type === 'invoice.paid') {
            await validateReferralForTenant(result.tenant_id);
          } else if (result.type === 'customer.subscription.deleted') {
            await revertReferralForTenant(result.tenant_id);
          }
        } catch (e) {
          request.log.error(`[referral] ${e.message}`);
        }
      }
      return reply.send({ received: true, ...result });
    } catch (e) {
      request.log.error(e);
      return reply.code(500).send({ error: 'Error procesando el evento', detail: e.message });
    }
  });

  // --- Informes Excel / PDF (Fase 5) ---
  async function handleReport(request, reply, format) {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (caller.role !== 'owner') {
      return reply.code(403).send({ error: 'Solo un Owner puede exportar informes' });
    }

    const { startDate, endDate, driverId, vehicleId, client, excludeClient, clients, excludeClients } = request.body ?? {};
    const filters = { tenantId: caller.tenant_id, startDate, endDate, driverId, vehicleId, client, excludeClient, clients, excludeClients };
    const ext = format === 'excel' ? 'xlsx' : 'pdf';
    const mime = format === 'excel' ? XLSX_MIME : 'application/pdf';
    const filename = `TaxiCount_export_${new Date().toISOString().slice(0, 10)}.${ext}`;

    // Caché (10 min) por tenant + filtros + formato
    const key = cacheKey(format, filters);
    const cached = getCached(key);
    let buffer;
    if (cached) {
      buffer = cached.buffer;
    } else {
      try {
        const generate = (async () => {
          const data = await fetchReportData(supabase, filters);
          return format === 'excel' ? buildExcel(data) : buildPdf(data);
        })();
        buffer = await withTimeout(generate, REPORT_TIMEOUT_MS);
      } catch (e) {
        if (e.message === 'whisper-timeout') {
          return reply
            .code(504)
            .send({ error: 'La exportación ha tardado demasiado. Prueba con un rango de fechas más pequeño.' });
        }
        request.log.error(e);
        return reply.code(500).send({ error: 'No se pudo generar el informe', detail: e.message });
      }
      setCached(key, { buffer });
    }

    return reply
      .header('Content-Type', mime)
      .header('Content-Disposition', `attachment; filename="${filename}"`)
      .header('Content-Length', buffer.length)
      .send(buffer);
  }

  app.post('/api/v1/reports/excel', (req, reply) => handleReport(req, reply, 'excel'));
  app.post('/api/v1/reports/pdf', (req, reply) => handleReport(req, reply, 'pdf'));

  // --- Importar Excel/CSV antiguo (Owner) ---
  // Lee el fichero, reconoce las columnas y crea las transacciones conservando
  // la fecha original. ?type=income|expense|auto fija el tipo si el Excel no lo
  // trae (auto = por el signo del importe).
  app.post('/api/v1/import/transactions', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (caller.role !== 'owner') {
      return reply.code(403).send({ error: 'Solo un Owner puede importar datos' });
    }
    const defaultType = request.query?.type;
    const preview = request.query?.preview === 'true' || request.query?.preview === '1';
    const file = await request.file();
    if (!file) return reply.code(400).send({ error: 'Falta el fichero' });
    const buffer = await file.toBuffer();

    // Opción B: si las reglas no reconocen las columnas, la IA (Groq) las mapea
    // a partir de las primeras filas. Solo mapea columnas; los valores los
    // calcula el código (no inventa cifras). Best-effort: si la IA falla, error claro.
    const aiMapper = (OPENAI_API_KEY && LLM_PARSE_MODEL)
      ? (sample) => llmMapColumns(sample, {
          apiKey: OPENAI_API_KEY, baseURL: OPENAI_BASE_URL, model: LLM_PARSE_MODEL,
        })
      : null;

    let parsed;
    try {
      parsed = await parseImportFile(buffer, file.filename, { defaultType, aiMapper });
    } catch (e) {
      return reply.code(400).send({ error: `No se pudo leer el fichero: ${e.message}` });
    }
    if (parsed.error === 'no_headers') {
      return reply.code(400).send({
        error: 'No reconozco las columnas. Asegúrate de que la primera fila tiene títulos (Fecha, Importe, Tipo, Categoría…).',
      });
    }
    if (!parsed.rows.length) {
      return reply.send({ imported: 0, skipped: parsed.skipped || 0, headers: parsed.headers || [], usedAi: parsed.usedAi || false });
    }

    // Vista previa: NO inserta; devuelve un resumen para que el usuario confirme.
    if (preview) {
      const sample = parsed.rows.slice(0, 15).map((r) => ({
        date: r.date instanceof Date ? r.date.toISOString().slice(0, 10) : null,
        amount: r.amount,
        type: r.type,
        category: r.category,
        payment: r.payment,
        description: r.description,
        driver: r.driver,
        plate: r.plate,
      }));
      return reply.send({
        imported: 0,
        preview: sample,
        total: parsed.rows.length,
        skipped: parsed.skipped || 0,
        usedAi: parsed.usedAi || false,
        headers: parsed.headers || [],
      });
    }

    const norm = (s) => (s ?? '').toString().toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').trim();
    const { data: users } = await supabase
      .from('users').select('id, email, name').eq('tenant_id', caller.tenant_id);
    const { data: vehicles } = await supabase
      .from('vehicles').select('id, license_plate').eq('tenant_id', caller.tenant_id);
    const userByKey = {};
    for (const u of users || []) {
      if (u.email) userByKey[norm(u.email)] = u.id;
      if (u.name) userByKey[norm(u.name)] = u.id;
    }
    const vehByPlate = {};
    for (const v of vehicles || []) {
      if (v.license_plate) vehByPlate[norm(v.license_plate)] = v.id;
    }

    const toInsert = parsed.rows.map((r) => ({
      tenant_id: caller.tenant_id,
      user_id: (r.driver && userByKey[norm(r.driver)]) || caller.id,
      amount: r.amount,
      type: r.type,
      category: r.category,
      payment_method: r.payment,
      description: r.description,
      vehicle_id: (r.plate && vehByPlate[norm(r.plate)]) || null,
      created_at: (r.date instanceof Date ? r.date : new Date()).toISOString(),
    }));

    let imported = 0;
    for (let i = 0; i < toInsert.length; i += 500) {
      const chunk = toInsert.slice(i, i + 500);
      const { error } = await supabase.from('transactions').insert(chunk);
      if (error) return reply.code(400).send({ error: error.message, imported });
      imported += chunk.length;
    }
    return reply.send({ imported, skipped: parsed.skipped || 0, headers: parsed.headers || [] });
  });

  return app;
}

async function start() {
  const app = await buildApp();
  try {
    await app.listen({ port: PORT, host: HOST });
    app.log.info(`TaxiCount backend escuchando en http://${HOST}:${PORT}`);
  } catch (err) {
    app.log.error(err);
    process.exit(1);
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  start();
}
