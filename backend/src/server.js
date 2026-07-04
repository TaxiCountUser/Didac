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

// Tope máximo de conductores del modelo por asiento. A partir de aquí, plan a
// medida (el cliente contacta con nosotros).
const MAX_DRIVERS = 100;

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
// Secreto para que un scheduler externo (cron-job.org, GitHub Actions, Render
// cron…) dispare los endpoints /api/v1/admin/cron/* sin un JWT de admin (que
// caduca). El scheduler manda la cabecera "x-cron-secret: <valor>". Si no se
// define, los crons solo aceptan un admin autenticado (comportamiento previo).
const CRON_SECRET = process.env.CRON_SECRET || '';
const STRIPE_SUCCESS_URL = process.env.STRIPE_SUCCESS_URL || 'taxicount://subscription-success';
const STRIPE_CANCEL_URL = process.env.STRIPE_CANCEL_URL || 'taxicount://subscription-cancel';
// Loop #6: cupón PERMANENTE de lanzamiento (p. ej. TAXI2026, 38%) que se aplica
// automáticamente en el checkout. Si está vacío, se permiten códigos manuales.
const STRIPE_LAUNCH_COUPON = process.env.STRIPE_LAUNCH_COUPON || '';
// Crédito (en céntimos) que se abona al jefe por cada reto completado por un
// conductor: "1 mes-asiento gratis". Por defecto 250 = 2,50 €.

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
  if (corsOrigin === true && process.env.NODE_ENV === 'production') {
    app.log.warn('[cors] CORS_ORIGIN no definido: se reflejará CUALQUIER origen. '
      + 'Define CORS_ORIGIN con la URL de tu web en producción.');
  }
  await app.register(cors, { origin: corsOrigin });
  await app.register(multipart, { limits: { fileSize: 25 * 1024 * 1024 } });

  // --- Cabeceras de seguridad (B-02, sin dependencias) ---
  app.addHook('onSend', async (_request, reply, payload) => {
    reply.header('X-Content-Type-Options', 'nosniff');
    reply.header('X-Frame-Options', 'DENY');
    reply.header('Referrer-Policy', 'no-referrer');
    return payload;
  });

  // --- Rate limit global por IP (M-04, sin dependencias) ---
  // Defensa básica anti-abuso/DoS. Excluye /health y /webhooks/* (el webhook de
  // Stripe ya valida firma y puede tener ráfagas legítimas). Configurable por env.
  const _ipBuckets = new Map();
  const RL_MAX = Number(process.env.RATE_LIMIT_MAX || 600);
  const RL_WINDOW = Number(process.env.RATE_LIMIT_WINDOW_MS || 60000);
  app.addHook('onRequest', async (request, reply) => {
    const url = request.url || '';
    if (url === '/health' || url.startsWith('/webhooks/')) return;
    const ip = request.ip || 'unknown';
    const now = Date.now();
    const b = _ipBuckets.get(ip);
    if (!b || now > b.reset) {
      _ipBuckets.set(ip, { count: 1, reset: now + RL_WINDOW });
      return;
    }
    b.count += 1;
    if (b.count > RL_MAX) {
      return reply.code(429).send({ error: 'Demasiadas peticiones, prueba en un minuto' });
    }
  });

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
    sentry: !!SENTRY_DSN, // captura de errores activa si hay SENTRY_DSN
    timestamp: new Date().toISOString(),
  }));

  // Config pública de la app (sin auth): modo mantenimiento y su mensaje. La app
  // la consulta al arrancar para mostrar un aviso a todos los usuarios.
  app.get('/api/v1/app-config', async (_request, reply) => {
    let maintenance = false;
    let message = '';
    try {
      const { data } = await supabase.from('system_config')
        .select('key, value').in('key', ['maintenance_mode', 'maintenance_message']);
      for (const r of data ?? []) {
        if (r.key === 'maintenance_mode') maintenance = r.value === 'true';
        if (r.key === 'maintenance_message') message = r.value ?? '';
      }
    } catch { /* sin config -> sin mantenimiento */ }
    return reply.send({ maintenance, maintenance_message: message });
  });

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

    // Obtener el audio: multipart (campo 'audio') o, en tests, mock_text.
    // (N-01) Se eliminó el branch `storagePath`: el cliente nunca lo usa y
    // descargar una ruta arbitraria con service_role omitía la RLS del bucket
    // (IDOR latente). El audio llega siempre por multipart.
    let buffer = null;
    let filename = 'audio.m4a';
    let mockText = null;

    if (request.isMultipart()) {
      const file = await request.file();
      if (file?.fieldname === 'audio' || file) {
        filename = file.filename || filename;
        buffer = await file.toBuffer();
      }
    } else {
      const body = request.body || {};
      mockText = body.mock_text || null;
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
      return reply.code(502).send({ error });
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

  // --- Login con NOMBRE DE USUARIO (P3-01) ---
  // El email se resuelve en el SERVIDOR (service_role) y el password-grant se
  // hace contra GoTrue aquí; al cliente solo le devolvemos los tokens. Así un
  // anónimo ya NO puede traducir username -> email (se quitó la RPC anónima).
  // Rate-limit por IP y por usuario (anti fuerza bruta / enumeración).
  app.post('/api/v1/auth/login-username', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const { username, password } = request.body ?? {};
    const u = (username == null ? '' : String(username)).trim();
    if (!u || !password) return reply.code(400).send({ error: 'Faltan credenciales' });
    if (rateLimited(`loginu:ip:${request.ip}`, 30, 60000) ||
        rateLimited(`loginu:u:${u.toLowerCase()}`, 10, 60000)) {
      return reply.code(429).send({ error: 'Demasiados intentos, prueba en un minuto' });
    }
    // Respuesta genérica para no revelar si el usuario existe.
    const genErr = () => reply.code(401).send({ error: 'Usuario o contraseña incorrectos' });
    const { data: row } = await supabase
      .from('users').select('email').ilike('username', u).maybeSingle();
    if (!row?.email) return genErr();
    try {
      const resp = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
        method: 'POST',
        headers: { apikey: SUPABASE_SERVICE_ROLE_KEY, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: row.email, password: String(password) }),
      });
      const tok = await resp.json().catch(() => ({}));
      if (!resp.ok || !tok.access_token) return genErr();
      return reply.send({ access_token: tok.access_token, refresh_token: tok.refresh_token });
    } catch (e) {
      request.log.error(e);
      return reply.code(502).send({ error: 'No se pudo iniciar sesión' });
    }
  });

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

    // Tope máximo del modelo por asiento: 100 conductores. A partir de ahí, el
    // cliente debe contactar con nosotros (plan a medida). Se aplica siempre,
    // también en prueba.
    const { count: driverCount } = await supabase
      .from('users')
      .select('id', { count: 'exact', head: true })
      .eq('tenant_id', caller.tenant_id)
      .eq('role', 'driver');
    if ((driverCount ?? 0) >= MAX_DRIVERS) {
      return reply.code(403).send({
        error: `Has alcanzado el máximo de ${MAX_DRIVERS} conductores. Contacta con nosotros para ampliar tu flota.`,
      });
    }

    // Límite por plan (legado, p. ej. planes antiguos con drivers_limit). En el
    // modelo por asiento drivers_limit es null y este bloque no aplica.
    const { data: tenant } = await supabase
      .from('tenants')
      .select('drivers_limit, subscription_status')
      .eq('id', caller.tenant_id)
      .single();
    const limit = tenant?.drivers_limit;
    const paid = tenant?.subscription_status === 'active' || tenant?.subscription_status === 'past_due';
    if (paid && limit !== null && limit !== undefined && (driverCount ?? 0) >= limit) {
      return reply.code(403).send({ error: 'Has alcanzado el límite de conductores de tu plan' });
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

    // No registrar nunca la contraseña temporal (queda en logs de Render/Sentry).
    app.log.info(`[create-driver] ${email} creado en tenant ${caller.tenant_id}`);
    // M-05: la contraseña es temporal -> obligar a cambiarla en el primer login.
    await supabase.from('users').update({ must_change_password: true }).eq('id', created.user.id);
    await syncSeatQuantity(caller.tenant_id); // ajusta la factura por asiento
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
    // M-05: si el jefe resetea la contraseña, es temporal -> forzar cambio.
    if (password !== undefined && password !== null && password !== '') {
      patch.must_change_password = true;
    }
    if (username !== undefined) {
      const u = (username == null ? '' : String(username)).trim();
      patch.username = u === '' ? null : u;
    }
    if (name !== undefined) {
      const n = (name == null ? '' : String(name)).trim();
      patch.name = n === '' ? null : n;
      // Un solo nombre en toda la app: si el jefe renombra, el conductor también
      // lo ve (display_name sincronizado; el último que escribe gana).
      patch.display_name = patch.name;
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

    // Activar/desactivar un conductor cambia los asientos facturables.
    if (active !== undefined) await syncSeatQuantity(guard.driver.tenant_id);
    return reply.send({ ok: true, id: driverId });
  });

  // --- Dar de baja un conductor (Loop #6: baja LÓGICA, no borrado) ---
  // El jefe no puede eliminar conductores: se conserva la cuenta y su historial
  // (carreras, lecturas...) y solo se marca active=false. Deja de contar como
  // asiento facturable y no puede iniciar sesión (lo verifica la app).
  app.delete('/api/v1/drivers/:id', async (request, reply) => {
    const driverId = request.params.id;
    const guard = await ownerDriverGuard(request, driverId);
    if (guard.error) return reply.code(guard.code).send({ error: guard.error });

    const { error: uErr } = await supabase.from('users').update({ active: false }).eq('id', driverId);
    if (uErr) return reply.code(400).send({ error: `No se pudo dar de baja: ${uErr.message}` });
    await syncSeatQuantity(guard.driver.tenant_id); // baja un asiento de la factura
    return reply.send({ ok: true, id: driverId, deactivated: true });
  });

  // ============================================================
  // Panel de administrador de plataforma (is_admin).
  // Ve y gestiona TODAS las empresas e incidencias. Va por service_role, pero
  // SIEMPRE verifica que el llamante es admin antes de devolver nada.
  // ============================================================
  async function adminGuard(request) {
    // Memoiza el resultado en la request: el preHandler centralizado y el guard
    // por endpoint comparten una sola verificación (sin doblar llamadas de red).
    if (request._adminGuard) return request._adminGuard;
    let result;
    if (!supabase) result = { code: 500, error: 'Supabase no configurado' };
    else {
      const caller = await getCaller(request);
      if (!caller) result = { code: 401, error: 'No autenticado' };
      else if (!caller.is_admin) result = { code: 403, error: 'Solo un administrador puede acceder' };
      else result = { caller };
    }
    request._adminGuard = result;
    return result;
  }

  // Registra la última ejecución de un cron (para los semáforos del panel de
  // admin). Best-effort: nunca rompe el cron si falla.
  async function markCronRun(name) {
    try {
      await supabase.from('system_config').upsert(
        { key: `cron_last_${name}`, value: new Date().toISOString() }, { onConflict: 'key' });
    } catch (e) {
      app.log.warn(`[cron] no se pudo registrar cron_last_${name}: ${e.message}`);
    }
  }

  // ¿Viene de un scheduler externo con el secreto de cron correcto?
  function cronAuthorized(request) {
    return !!CRON_SECRET && request.headers['x-cron-secret'] === CRON_SECRET;
  }

  // Autoriza un endpoint de cron: acepta el secreto de cron O un admin. Devuelve
  // { caller } (caller = null si viene por secreto) o { code, error }.
  async function cronOrAdmin(request) {
    if (cronAuthorized(request)) return { caller: null, viaCron: true };
    return adminGuard(request);
  }

  // Defensa en profundidad: TODA ruta /api/v1/admin/* exige admin aquí, aunque
  // el handler también lo verifique. Así un endpoint admin nuevo no puede quedar
  // sin protección por olvido. La memoización evita la doble verificación.
  // Excepción: /api/v1/admin/cron/* con el secreto de cron válido (schedulers).
  app.addHook('preHandler', async (request, reply) => {
    const path = (request.url || '').split('?')[0];
    if (!path.startsWith('/api/v1/admin/')) return;
    if (path.startsWith('/api/v1/admin/cron/') && cronAuthorized(request)) return;
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
  });

  // Registra una acción administrativa sensible en admin_actions_log (auditoría).
  // Best-effort: si falla, no rompe la operación principal.
  async function logAdminAction(request, adminId, actionType, targetType, targetId, details) {
    if (!supabase) return;
    try {
      await supabase.from('admin_actions_log').insert({
        admin_id: adminId ?? null,
        action_type: actionType,
        target_type: targetType ?? null,
        target_id: targetId != null ? String(targetId) : null,
        details: details ?? null,
        ip_address: request?.ip ?? null,
      });
    } catch (e) {
      app.log.warn(`[audit] no se pudo registrar acción ${actionType}: ${e.message}`);
    }
  }

  // ============================================================
  // Loop #6 - Informes de error enviados desde la app.
  // Van al ADMIN (panel completo) con COPIA por push al JEFE de la flota, que
  // solo puede verlos (RLS de error_reports): ni modifica, ni borra, ni
  // responde. Es una tabla aparte de incidents -> no sale en "Mensajes al jefe".
  // ============================================================

  // Cualquier usuario autenticado (conductor/jefe) envía un informe de error.
  app.post('/api/v1/error-reports', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    const b = request.body ?? {};
    const description = String(b.description ?? '').trim();
    if (description.length < 3) return reply.code(400).send({ error: 'Describe el error (mínimo 3 caracteres)' });
    if (description.length > 4000) return reply.code(400).send({ error: 'La descripción es demasiado larga' });
    const screenshotUrl = b.screenshot_url ? String(b.screenshot_url).slice(0, 1000) : null;
    const deviceInfo = b.device_info ? String(b.device_info).slice(0, 1000) : null;

    const { data: row, error } = await supabase.from('error_reports').insert({
      tenant_id: caller.tenant_id ?? null,
      user_id: caller.id,
      description, screenshot_url: screenshotUrl, device_info: deviceInfo,
    }).select('id').maybeSingle();
    if (error) return reply.code(400).send({ error: error.message });

    // Push a todos los admins + copia al/los jefe(s) de la flota.
    try {
      const { data: me } = await supabase.from('users').select('name, email').eq('id', caller.id).maybeSingle();
      const reporter = me?.name || me?.email || 'Un usuario';
      const preview = description.length > 120 ? `${description.slice(0, 117)}…` : description;
      const { data: admins } = await supabase.from('users').select('id').eq('is_admin', true);
      for (const a of admins ?? []) {
        await notifyUser(a.id, '🐞 Nuevo informe de error', `${reporter}: ${preview}`,
          { type: 'error_report', report_id: String(row?.id ?? '') });
      }
      if (caller.tenant_id) {
        const { data: owners } = await supabase.from('users')
          .select('id').eq('tenant_id', caller.tenant_id).eq('role', 'owner');
        for (const o of owners ?? []) {
          if (o.id === caller.id) continue;
          await notifyUser(o.id, 'Informe de error enviado',
            `${reporter} ha reportado un problema. El equipo de TaxiCount lo revisará.`,
            { type: 'error_report_copy', report_id: String(row?.id ?? '') });
        }
      }
    } catch (e) {
      app.log.warn(`[error-report] push falló: ${e.message}`);
    }
    return reply.code(201).send({ ok: true, id: row?.id });
  });

  // Admin: listar informes de error. Filtros: ?status= &tenant_id=.
  app.get('/api/v1/admin/error-reports', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    let q = supabase.from('error_reports')
      .select('id, tenant_id, user_id, description, screenshot_url, device_info, status, '
        + 'created_at, reviewed_at, users:user_id(email, name), tenants:tenant_id(name)')
      .order('created_at', { ascending: false }).limit(1000);
    const qp = request.query ?? {};
    if (qp.status) q = q.eq('status', String(qp.status));
    if (qp.tenant_id) q = q.eq('tenant_id', String(qp.tenant_id));
    const { data, error } = await q;
    if (error) return reply.code(500).send({ error: error.message });
    return reply.send({ reports: data ?? [] });
  });

  // Admin: cambiar el estado de un informe. Al marcarlo 'resolved' se avisa por
  // push al usuario que lo reportó.
  app.patch('/api/v1/admin/error-reports/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const status = String((request.body ?? {}).status ?? '');
    const allowed = ['new', 'viewed', 'in_progress', 'resolved'];
    if (!allowed.includes(status)) return reply.code(400).send({ error: 'Estado no válido' });

    const patch = { status };
    if (status === 'resolved') patch.reviewed_at = new Date().toISOString();
    const { data: row, error } = await supabase.from('error_reports')
      .update(patch).eq('id', request.params.id).select('id, user_id').maybeSingle();
    if (error) return reply.code(400).send({ error: error.message });
    if (!row) return reply.code(404).send({ error: 'Informe no encontrado' });

    await logAdminAction(request, g.caller.id, 'error_report_status', 'error_reports', row.id, { status });
    if (status === 'resolved' && row.user_id) {
      try {
        await notifyUser(row.user_id, '✅ Informe resuelto',
          'El problema que reportaste ha sido resuelto. ¡Gracias por avisar!',
          { type: 'error_report_resolved', report_id: String(row.id) });
      } catch { /* no-op */ }
    }
    return reply.send({ ok: true, id: row.id, status });
  });

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

    // ---- Panel rediseñado (Fase 1): KPIs, pendientes, bandeja de trabajo,
    // estado de crons y salud de la plataforma. Campos NUEVOS: la UI antigua
    // sigue leyendo tenants/totals sin cambios.
    const now = Date.now();
    const dayMs = 86400000;
    const paying = rows.filter((t) => t.subscription_status === 'active' || t.subscription_status === 'past_due');
    const payingIds = new Set(paying.map((t) => t.id));
    const pastDue = rows.filter((t) => t.subscription_status === 'past_due');
    const inTrial = rows.filter((t) => !payingIds.has(t.id) && t.trial_ends_at && new Date(t.trial_ends_at).getTime() > now);
    const trialSoon = inTrial.filter((t) => new Date(t.trial_ends_at).getTime() - now <= 5 * dayMs);

    // Conductores y MRR estimado (annual_price_paid/12 de los activos de pago).
    const { data: drivers } = await supabase.from('users')
      .select('tenant_id, active, annual_price_paid').eq('role', 'driver');
    const activeByTenant = {};
    let driversTotal = 0;
    let driversActive = 0;
    let mrr = 0;
    for (const d of drivers ?? []) {
      driversTotal++;
      if (d.active !== false) {
        driversActive++;
        (activeByTenant[d.tenant_id] ||= []).push(Number(d.annual_price_paid ?? 15));
      }
    }
    for (const t of paying) {
      const seats = activeByTenant[t.id] ?? [];
      if (seats.length === 0) { mrr += 15 / 12; continue; } // autónomo: su propio asiento
      for (const p of seats) mrr += p / 12;
    }

    // Pendientes por tipo (acotados; solo lo abierto/no resuelto).
    const { data: refAlerts } = await supabase.from('referral_fraud_alerts')
      .select('id, type, detail, severity, created_at').is('resolved_at', null)
      .order('created_at', { ascending: false }).limit(100);
    const { data: genAlerts } = await supabase.from('fraud_alerts')
      .select('id, alert_type, description, severity, tenant_id, created_at').is('resolved_at', null)
      .order('created_at', { ascending: false }).limit(100);
    const { data: tickets } = await supabase.from('incidents')
      .select('id, body, created_at, tenant_id, tenants(name)')
      .eq('kind', 'app').eq('status', 'abierta')
      .order('created_at', { ascending: true }).limit(100);
    const { data: errNew } = await supabase.from('error_reports')
      .select('id, description, created_at, tenants:tenant_id(name)').eq('status', 'new')
      .order('created_at', { ascending: false }).limit(100);
    const { data: suspicious } = await supabase.from('challenge_claims')
      .select('id, tenant_id, user_id, created_at, users:user_id(name, email), tenants:tenant_id(name)')
      .eq('suspicious', true).eq('status', 'rewarded').is('reward_redeemed_at', null)
      .order('created_at', { ascending: false }).limit(100);

    const fraudOpen = (refAlerts?.length ?? 0) + (genAlerts?.length ?? 0);
    const ticketsOld = (tickets ?? []).filter((i) => now - new Date(i.created_at).getTime() > dayMs).length;

    // Bandeja de trabajo: lo accionable de todos los módulos, priorizado.
    const inbox = [];
    for (const a of refAlerts ?? []) {
      inbox.push({ type: 'fraud', id: a.id, title: a.detail || a.type || 'Alerta de referidos',
        subtitle: `referidos · ${a.severity ?? ''}`.trim(), created_at: a.created_at, module: 'security' });
    }
    for (const a of genAlerts ?? []) {
      inbox.push({ type: 'fraud', id: a.id, title: a.description || a.alert_type || 'Alerta de fraude',
        subtitle: a.severity ?? '', tenant_id: a.tenant_id, created_at: a.created_at, module: 'security' });
    }
    for (const c of suspicious ?? []) {
      inbox.push({ type: 'challenge', id: c.id,
        title: `Reto sospechoso de ${c.users?.name || c.users?.email || 'conductor'}`,
        subtitle: c.tenants?.name ?? '', tenant_id: c.tenant_id, created_at: c.created_at, module: 'challenges' });
    }
    for (const i of tickets ?? []) {
      inbox.push({ type: 'ticket', id: i.id, title: (i.body || '').slice(0, 90),
        subtitle: i.tenants?.name ?? '', tenant_id: i.tenant_id, created_at: i.created_at, module: 'incidents' });
    }
    for (const t of trialSoon) {
      const days = Math.max(0, Math.ceil((new Date(t.trial_ends_at).getTime() - now) / dayMs));
      inbox.push({ type: 'trial', id: t.id, title: `La prueba de ${t.name} acaba en ${days} día${days === 1 ? '' : 's'}`,
        subtitle: `${t.users_count} usuarios`, tenant_id: t.id, created_at: t.trial_ends_at, module: 'company' });
    }
    for (const e of errNew ?? []) {
      inbox.push({ type: 'error', id: e.id, title: (e.description || '').slice(0, 90),
        subtitle: e.tenants?.name ?? '', created_at: e.created_at, module: 'errors' });
    }
    const prio = { fraud: 0, challenge: 1, ticket: 2, trial: 3, error: 4 };
    inbox.sort((a, b) => (prio[a.type] - prio[b.type])
      || (new Date(a.created_at).getTime() - new Date(b.created_at).getTime()));

    // Última ejecución de cada cron (markCronRun) para los semáforos.
    const { data: cronRows } = await supabase.from('system_config')
      .select('key, value').like('key', 'cron_last_%');
    const crons = {};
    for (const r of cronRows ?? []) crons[r.key.replace('cron_last_', '')] = r.value;
    const cronStale = ['challenge_credits', 'referral_validations'].some((k) => {
      const v = crons[k];
      return !v || now - new Date(v).getTime() > 2 * dayMs;
    });

    // Salud 0-100: penaliza fraude abierto, tickets envejecidos, impagos,
    // crons parados y errores nuevos. Transparente y estable.
    let health = 100;
    health -= Math.min(30, fraudOpen * 15);
    health -= Math.min(15, ticketsOld * 5);
    health -= pastDue.length > 0 ? 10 : 0;
    health -= cronStale ? 10 : 0;
    health -= Math.min(10, (errNew?.length ?? 0) * 2);
    health = Math.max(0, Math.round(health));

    return reply.send({
      tenants: rows,
      totals: {
        tenants: rows.length,
        users: (users || []).length,
        open_incidents: (openInc || []).length,
      },
      kpis: {
        tenants: rows.length,
        paying: paying.length,
        trialing: inTrial.length,
        past_due: pastDue.length,
        drivers_total: driversTotal,
        drivers_active: driversActive,
        mrr_estimate: Number(mrr.toFixed(2)),
      },
      pending: {
        fraud: fraudOpen,
        challenges: suspicious?.length ?? 0,
        tickets: tickets?.length ?? 0,
        trials_ending: trialSoon.length,
        errors: errNew?.length ?? 0,
      },
      inbox: inbox.slice(0, 12),
      crons,
      health,
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
    // Conceder/revocar admin es la acción más sensible: queda en auditoría.
    await logAdminAction(request, g.caller.id, isAdmin === false ? 'admin_revoke' : 'admin_grant',
      'user', data[0].id, { email: data[0].email, is_admin: data[0].is_admin });
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
      .select('id, email, name, display_name, username, role, active, is_admin, created_at, annual_price_paid')
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

    // PROTECCIÓN DE DATOS: el admin de plataforma NO ve el dinero de las empresas
    // ni el contenido de las carreras (importes, ingresos/gastos, cliente,
    // origen/destino, descripción). Solo damos recuentos, nunca las cifras ni el
    // detalle. Así TaxiCount no accede al contenido económico/de cliente.
    const summary = null; // enmascarado (*****)

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

    // Datos de SUSCRIPCIÓN (lado TaxiCount, no finanzas del cliente): cuota
    // mensual estimada (annual_price_paid/12 de los conductores activos) y días
    // gratis conseguidos (retos + referidos). Para la ficha rediseñada.
    let mrrCompany = 0;
    const activeDrivers = (users || []).filter((u) => u.role === 'driver' && u.active !== false);
    if ((tenant.subscription_status === 'active' || tenant.subscription_status === 'past_due')) {
      if (activeDrivers.length === 0) mrrCompany = 15 / 12;
      for (const u of activeDrivers) mrrCompany += Number(u.annual_price_paid ?? 15) / 12;
    }
    const freeDays = await freeDaysForTenant(id);

    return reply.send({
      tenant,
      users: users || [],
      counts: { vehicles, transactions, incidents },
      summary,                       // null: oculto por protección de datos
      recent_transactions: [],       // oculto por protección de datos
      financials_masked: true,       // el front muestra ***** en vez de cifras
      vehicles_list: vehicleList || [],
      incidents_list: incidentList || [],
      billing: {
        mrr_estimate: Number(mrrCompany.toFixed(2)),
        free_days: freeDays.total,
        free_days_challenges: freeDays.challenges,
        free_days_referrals: freeDays.referrals,
        active_drivers: activeDrivers.length,
      },
    });
  });

  // Módulo Facturación del panel (Fase 3): visión de negocio lado TaxiCount.
  // MRR estimado por empresa (annual_price_paid/12 de conductores activos),
  // impagados, pruebas próximas a vencer y ahorro total repartido. NUNCA
  // finanzas internas de los clientes (protección de datos).
  app.get('/api/v1/admin/billing', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const now = Date.now();
    const dayMs = 86400000;

    const [{ data: tenants }, { data: drivers }, { data: exts }, { data: milestones }] = await Promise.all([
      supabase.from('tenants')
        .select('id, name, subscription_status, trial_ends_at, drivers_limit, created_at')
        .order('created_at', { ascending: false }),
      supabase.from('users').select('id, tenant_id, active, annual_price_paid, role'),
      supabase.from('subscription_extensions').select('tenant_id, days_extended').eq('extension_type', 'challenge'),
      supabase.from('referral_milestone_rewards').select('user_id, days_awarded'),
    ]);

    // Días gratis por retos (por tenant) y por referidos (por owner -> tenant).
    const ownerTenant = {};
    const seatsByTenant = {};
    for (const u of drivers ?? []) {
      if (u.role === 'owner') ownerTenant[u.id] = u.tenant_id;
      if (u.role === 'driver' && u.active !== false) {
        (seatsByTenant[u.tenant_id] ||= []).push(Number(u.annual_price_paid ?? 15));
      }
    }
    const daysByTenant = {};
    let daysCh = 0;
    let daysRef = 0;
    for (const e of exts ?? []) {
      const d = e.days_extended ?? 0;
      daysByTenant[e.tenant_id] = (daysByTenant[e.tenant_id] ?? 0) + d;
      daysCh += d;
    }
    for (const m of milestones ?? []) {
      const tid = ownerTenant[m.user_id];
      const d = m.days_awarded ?? 0;
      if (tid) daysByTenant[tid] = (daysByTenant[tid] ?? 0) + d;
      daysRef += d;
    }

    let mrrTotal = 0;
    const rows = (tenants ?? []).map((t) => {
      const paying = t.subscription_status === 'active' || t.subscription_status === 'past_due';
      const seats = seatsByTenant[t.id] ?? [];
      let mrr = 0;
      if (paying) {
        if (seats.length === 0) mrr = 15 / 12;
        for (const p of seats) mrr += p / 12;
        mrrTotal += mrr;
      }
      const trialEnds = t.trial_ends_at ? new Date(t.trial_ends_at).getTime() : null;
      const trialDays = (!paying && trialEnds && trialEnds > now)
        ? Math.ceil((trialEnds - now) / dayMs) : null;
      return {
        id: t.id, name: t.name, status: t.subscription_status,
        seats: Math.max(1, seats.length), drivers_limit: t.drivers_limit,
        mrr: Number(mrr.toFixed(2)), trial_days_left: trialDays,
        free_days: daysByTenant[t.id] ?? 0,
      };
    });

    return reply.send({
      totals: {
        mrr: Number(mrrTotal.toFixed(2)),
        paying: rows.filter((r) => r.status === 'active').length,
        past_due: rows.filter((r) => r.status === 'past_due').length,
        trialing: rows.filter((r) => r.trial_days_left != null).length,
        free_days_total: daysCh + daysRef,
        free_days_challenges: daysCh,
        free_days_referrals: daysRef,
      },
      past_due: rows.filter((r) => r.status === 'past_due'),
      trials: rows.filter((r) => r.trial_days_left != null)
        .sort((a, b) => a.trial_days_left - b.trial_days_left),
      paying: rows.filter((r) => r.status === 'active')
        .sort((a, b) => b.mrr - a.mrr),
    });
  });

  // Buscador global del admin: empresa por nombre, usuario por email/nombre/
  // usuario, o vehículo por matrícula. Devuelve empresas con el motivo del
  // match, para saltar directamente a su ficha.
  app.get('/api/v1/admin/search', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const q = String(request.query?.q ?? '').trim();
    if (q.length < 2) return reply.send({ results: [] });
    const like = `%${q}%`;

    const [byTenant, byUser, byPlate] = await Promise.all([
      supabase.from('tenants').select('id, name').ilike('name', like).limit(10),
      supabase.from('users')
        .select('tenant_id, email, name, username, tenants:tenant_id(id, name)')
        .or(`email.ilike.${like},name.ilike.${like},username.ilike.${like}`)
        .not('tenant_id', 'is', null).limit(10),
      supabase.from('vehicles')
        .select('tenant_id, license_plate, tenants:tenant_id(id, name)')
        .ilike('license_plate', like).limit(10),
    ]);

    const results = [];
    const seen = new Set();
    const push = (id, name, reason) => {
      if (!id || seen.has(`${id}|${reason}`)) return;
      seen.add(`${id}|${reason}`);
      results.push({ tenant_id: id, tenant_name: name ?? '—', reason });
    };
    for (const t of byTenant.data ?? []) push(t.id, t.name, '');
    for (const u of byUser.data ?? []) {
      push(u.tenants?.id ?? u.tenant_id, u.tenants?.name,
        u.email ?? u.username ?? u.name ?? '');
    }
    for (const v of byPlate.data ?? []) {
      push(v.tenants?.id ?? v.tenant_id, v.tenants?.name, v.license_plate ?? '');
    }
    return reply.send({ results: results.slice(0, 15) });
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
    await logAdminAction(request, g.caller.id, 'vehicle_add', 'tenant', request.params.id,
      { license_plate: String(license_plate).trim() });
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
    await logAdminAction(request, g.caller.id, 'vehicle_update', 'vehicle', request.params.id, patch);
    return reply.send({ ok: true });
  });

  // Eliminar un vehículo (admin).
  app.delete('/api/v1/admin/vehicle/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { error } = await supabase.from('vehicles').delete().eq('id', request.params.id);
    if (error) return reply.code(400).send({ error: error.message });
    await logAdminAction(request, g.caller.id, 'vehicle_delete', 'vehicle', request.params.id, null);
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
    await logAdminAction(request, g.caller.id, 'company_update', 'tenant', request.params.id, patch);
    return reply.send({ ok: true });
  });

  // Eliminar una empresa entera: borra el tenant (cascada a usuarios, vehículos,
  // transacciones, incidencias…) y las cuentas de auth de sus usuarios.
  app.delete('/api/v1/admin/company/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const id = request.params.id;

    // CIERRE LÓGICO con retención fiscal (5 años): NO borramos la empresa (eso
    // borraría en cascada sus carreras). Marcamos closed_at, anonimizamos y
    // eliminamos las cuentas de acceso; las carreras quedan (user_id -> null) y
    // se purgan a los 5 años (purge_expired_retention).
    const { data: users } = await supabase.from('users').select('id, is_admin').eq('tenant_id', id);
    const { error } = await supabase.from('tenants').update({
      closed_at: new Date().toISOString(),
      name: 'Empresa dada de baja',
      subscription_status: 'canceled',
      stripe_customer_id: null,
      stripe_subscription_id: null,
      join_code: null,
    }).eq('id', id);
    if (error) return reply.code(400).send({ error: error.message });
    // Elimina las cuentas de acceso de la empresa. IMPORTANTE: un admin de
    // plataforma NUNCA pierde su cuenta (aunque fuera propietario de esta
    // empresa): solo se le desvincula (tenant_id = null). Los demás pierden el
    // acceso; sus carreras se conservan (user_id -> null por ON DELETE SET NULL).
    let removed = 0;
    for (const u of users || []) {
      if (u.is_admin) {
        await supabase.from('users').update({ tenant_id: null }).eq('id', u.id);
        continue;
      }
      try { await supabase.auth.admin.deleteUser(u.id); } catch (_) {}
      removed += 1;
    }
    await logAdminAction(request, g.caller.id, 'company_close', 'tenant', id,
      { removed_access: removed });
    return reply.send({ ok: true, closed: true, removed_access: removed });
  });

  // Purga de retención: elimina definitivamente las empresas cerradas hace más
  // de 5 años (cascada a sus carreras). Pensado para ejecutarse periódicamente
  // (cron externo o manual). Devuelve cuántas se eliminaron.
  app.post('/api/v1/admin/cron/purge-retention', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { data, error } = await supabase.rpc('purge_expired_retention');
    if (error) return reply.code(500).send({ error: error.message });
    await markCronRun('purge_retention');
    await logAdminAction(request, g.caller.id, 'purge_retention', 'tenant', null, { purged: data ?? 0 });
    return reply.send({ ok: true, purged: data ?? 0 });
  });

  // Extiende la suscripción de un tenant N días (1 mes = 30). Si trial_ends_at
  // está en el pasado, cuenta desde hoy. Es el mecanismo común de "mes/días
  // gratis" para retos y referidos (ya no se usa crédito Stripe).
  async function extendTenantTrial(tenantId, deltaDays) {
    if (!tenantId || !deltaDays) return;
    const { data: t } = await supabase.from('tenants')
      .select('trial_ends_at').eq('id', tenantId).maybeSingle();
    const now = Date.now();
    const cur = t?.trial_ends_at ? new Date(t.trial_ends_at).getTime() : now;
    const base = cur > now ? cur : now;
    await supabase.from('tenants')
      .update({ trial_ends_at: new Date(base + deltaDays * 86400000).toISOString() })
      .eq('id', tenantId);
  }

  // ¿El tenant es cliente DE PAGO? Las recompensas (mes de retos / días de
  // referidos) solo se aplican sobre una suscripción activa; durante la PRUEBA
  // se difieren (no tiene sentido alargar una prueba que ya es gratis).
  async function tenantIsPaying(tenantId) {
    const { data: t } = await supabase.from('tenants')
      .select('subscription_status').eq('id', tenantId).maybeSingle();
    return t?.subscription_status === 'active' || t?.subscription_status === 'past_due';
  }

  async function applyPendingChallengeCredits() {
    const { data: claims } = await supabase
      .from('challenge_claims')
      .select('id, tenant_id, user_id')
      .eq('status', 'rewarded')
      .is('reward_redeemed_at', null)
      .limit(1000);
    let rewarded = 0;
    let deferred = 0;
    let skipped = 0;
    for (const c of claims ?? []) {
      // Solo se premia si la empresa ya es de PAGO. En prueba se deja pendiente
      // (sin marcar canjeado) y el cron lo aplicará cuando pase a suscripción.
      if (!(await tenantIsPaying(c.tenant_id))) { deferred++; continue; }
      const { data: u } = await supabase.from('users')
        .select('annual_price_paid').eq('id', c.user_id).maybeSingle();
      const monthlyValue = Number(u?.annual_price_paid ?? 15) / 12;
      try {
        const now = new Date();
        // Recompensa: 1 MES GRATIS (extiende la suscripción 30 días), por el
        // valor de un conductor. Antes era crédito Stripe; ahora extensión.
        await extendTenantTrial(c.tenant_id, 30);
        await supabase.from('subscription_extensions').insert({
          user_id: c.user_id, tenant_id: c.tenant_id, extension_type: 'challenge',
          source_id: c.id, days_extended: 30, monthly_value: monthlyValue.toFixed(2),
          extended_until: new Date(now.getTime() + 30 * 86400000).toISOString(),
        });
        await supabase.from('challenge_claims')
          .update({ reward_redeemed_at: now.toISOString() }).eq('id', c.id);
        rewarded++;
      } catch (e) {
        app.log.warn(`[challenge-reward] claim ${c.id}: ${e.message}`);
        skipped++;
      }
    }
    return { rewarded, deferred, skipped };
  }

  // Días gratis conseguidos por un tenant: por RETOS (subscription_extensions
  // type=challenge) y por REFERIDOS (referral_milestone_rewards de sus owners).
  // Es el "ahorro" real del nuevo modelo, medido en días de suscripción gratis.
  async function freeDaysForTenant(tenantId) {
    const { data: exts } = await supabase.from('subscription_extensions')
      .select('days_extended').eq('tenant_id', tenantId).eq('extension_type', 'challenge');
    const challenges = (exts ?? []).reduce((s, r) => s + (r.days_extended ?? 0), 0);
    const { data: owners } = await supabase.from('users')
      .select('id').eq('tenant_id', tenantId).eq('role', 'owner');
    const ownerIds = (owners ?? []).map((o) => o.id);
    let referrals = 0;
    if (ownerIds.length) {
      const { data: rr } = await supabase.from('referral_milestone_rewards')
        .select('days_awarded').in('user_id', ownerIds);
      referrals = (rr ?? []).reduce((s, r) => s + (r.days_awarded ?? 0), 0);
    }
    return { challenges, referrals, total: challenges + referrals };
  }

  app.post('/api/v1/admin/cron/apply-challenge-credits', async (request, reply) => {
    const g = await cronOrAdmin(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const res = await applyPendingChallengeCredits();
    await markCronRun('challenge_credits');
    await logAdminAction(request, g.caller?.id ?? null, 'challenge_credits_apply', 'challenge_claims', null, res);
    return reply.send({ ok: true, ...res });
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
    await logAdminAction(request, g.caller.id, 'user_update', 'user', request.params.id, patch);
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
    await logAdminAction(request, g.caller.id, 'user_delete', 'user', id, null);
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

  // Nº de asientos (conductores) a facturar de un tenant. Mínimo 1: incluso un
  // autónomo sin conductores extra ocupa 1 asiento (él mismo).
  async function seatCount(tenantId) {
    const { count } = await supabase.from('users')
      .select('id', { count: 'exact', head: true })
      .eq('tenant_id', tenantId).eq('role', 'driver').eq('active', true);
    return Math.max(1, count ?? 0);
  }

  // Sincroniza la cantidad del item de la suscripción de Stripe con el nº de
  // conductores. Solo si hay suscripción de pago. Best-effort (no rompe la
  // operación principal si falla). Stripe prorratea el cambio automáticamente.
  async function syncSeatQuantity(tenantId) {
    if (!stripe || !tenantId) return;
    try {
      const { data: t } = await supabase.from('tenants')
        .select('stripe_subscription_id, subscription_status').eq('id', tenantId).maybeSingle();
      const subId = t?.stripe_subscription_id;
      if (!subId) return; // en prueba todavía no hay suscripción
      if (!['active', 'past_due', 'trialing'].includes(t?.subscription_status)) return;
      const qty = await seatCount(tenantId);
      const sub = await stripe.subscriptions.retrieve(subId);
      const item = sub.items?.data?.[0];
      if (!item) return;
      if (item.quantity === qty) return; // sin cambios
      await stripe.subscriptionItems.update(item.id, { quantity: qty });
      app.log.info(`[seats] tenant ${tenantId}: cantidad -> ${qty}`);
    } catch (e) {
      app.log.warn(`[seats] no se pudo sincronizar asientos de ${tenantId}: ${e.message}`);
    }
  }

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

    // Cantidad = nº de conductores (asientos). Stripe aplica los tramos por volumen.
    const quantity = await seatCount(caller.tenant_id);

    try {
      const session = await stripe.checkout.sessions.create({
        mode: 'subscription',
        line_items: [{ price: priceId, quantity }],
        success_url: STRIPE_SUCCESS_URL,
        cancel_url: STRIPE_CANCEL_URL,
        ...(tenant?.stripe_customer_id ? { customer: tenant.stripe_customer_id } : {}),
        // Oferta de lanzamiento: cupón permanente auto-aplicado. Si no hay cupón
        // configurado, se permiten códigos promocionales manuales (campañas).
        // (discounts y allow_promotion_codes son excluyentes en Stripe.)
        ...(STRIPE_LAUNCH_COUPON
          ? { discounts: [{ coupon: STRIPE_LAUNCH_COUPON }] }
          : { allow_promotion_codes: true }),
        metadata,
        subscription_data: { metadata },
        client_reference_id: caller.tenant_id,
      });
      return reply.send({ url: session.url, id: session.id });
    } catch (e) {
      request.log.error(e);
      return reply.code(502).send({ error: 'No se pudo crear la sesión de Checkout' });
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
      return reply.code(502).send({ error: 'No se pudo crear la sesión del portal' });
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
  // Loop #6: TODOS los parámetros de retos se leen de system_config (editables
  // desde el panel de admin sin desplegar). Valores por defecto entre paréntesis:
  //   challenge_100k_euros_enabled (false) - money_100k solo si 'true'
  //   challenge_days_required      (365)   - objetivo del reto de días
  //   challenge_km_target          (100000)- objetivo de km del nivel 1
  //   challenge_max_jump           (2000)  - salto de km sospechoso (anti-fraude)
  //   challenge_max_income         (1500)  - carrera € sospechosa (anti-fraude)
  // La clave interna 'days_300' se mantiene por compatibilidad de datos/UI.
  // Loop #8: la recompensa ya NO se configura (challenge_seat_credit_cents
  // obsoleta) — es annual_price_paid/12 del conductor, ver applyPendingChallengeCredits.
  async function challengeConfig() {
    let euros = false;
    let days = 365;
    let kmTarget = 100000;
    let moneyTarget = 100000;
    let maxJump = 2000;
    let maxIncome = 1500;
    let kmEnabled = true;
    let daysEnabled = true;
    let levelMultiplier = 2;
    let levelCycle = 4;
    try {
      const { data } = await supabase.from('system_config')
        .select('key, value')
        .in('key', ['challenge_100k_euros_enabled', 'challenge_days_required',
          'challenge_km_target', 'challenge_money_target', 'challenge_max_jump',
          'challenge_max_income', 'challenge_km_enabled', 'challenge_days_enabled',
          'challenge_level_multiplier', 'challenge_level_cycle']);
      for (const r of data ?? []) {
        switch (r.key) {
          case 'challenge_100k_euros_enabled': euros = r.value === 'true'; break;
          case 'challenge_days_required': days = parseInt(r.value, 10) || days; break;
          case 'challenge_km_target': kmTarget = parseInt(r.value, 10) || kmTarget; break;
          case 'challenge_money_target': moneyTarget = parseInt(r.value, 10) || moneyTarget; break;
          case 'challenge_max_jump': maxJump = parseInt(r.value, 10) || maxJump; break;
          case 'challenge_max_income': maxIncome = parseInt(r.value, 10) || maxIncome; break;
          case 'challenge_km_enabled': kmEnabled = r.value !== 'false'; break;
          case 'challenge_days_enabled': daysEnabled = r.value !== 'false'; break;
          case 'challenge_level_multiplier': levelMultiplier = parseInt(r.value, 10) || levelMultiplier; break;
          case 'challenge_level_cycle': levelCycle = parseInt(r.value, 10) || levelCycle; break;
          default: break;
        }
      }
    } catch { /* sin config -> valores por defecto */ }
    const base = {};
    if (kmEnabled) base.km_100k = kmTarget;
    if (euros) base.money_100k = moneyTarget;
    if (daysEnabled) base.days_300 = days;
    return {
      base, eurosEnabled: euros, daysRequired: days, maxJump, maxIncome,
      levelMultiplier, levelCycle,
    };
  }

  // Objetivo (incremento) de un reto en un nivel dado. Ciclo configurable: el
  // 1º de cada ciclo (niveles 1, cycle+1, 2·cycle+1...) vuelve a la base; los
  // demás, la base × multiplicador. Así de vez en cuando "baja" como sorpresa.
  const incrementFor = (base, challenge, level, mult = 2, cycle = 4) =>
    (base[challenge] ?? 0) * (((level - 1) % Math.max(1, cycle)) === 0 ? 1 : mult);

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
      const { base, maxJump: maxJumpCfg, maxIncome: maxIncomeCfg, levelMultiplier, levelCycle } = await challengeConfig();
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
        for (const type of Object.keys(base)) {
          const claims = (byUserChal[r.user_id]?.[type]) ?? [];
          const st = levelState(claims);
          const target = incrementFor(base, type, st.level, levelMultiplier, levelCycle);
          const metric = metrics[type];
          const progress = Math.max(0, metric - st.baseline);
          const reached = progress >= target;
          // Loop #6: al alcanzar el tramo se registra el logro como 'rewarded'
          // (auto-avance de nivel). La recompensa es 1 mes-asiento gratis al jefe
          // por conductor, que se aplica como crédito en Stripe (cron). Si hay
          // señales de fraude se marca `suspicious` para que lo revise el ADMIN
          // (ya no se avisa al jefe); el admin puede rechazarlo.
          if (reached && !st.pending && !st.rejected) {
            const suspicious = (type === 'km_100k' && maxJump > maxJumpCfg)
              || (type === 'money_100k' && maxIncome > maxIncomeCfg);
            const { error: insErr } = await supabase.from('challenge_claims').insert({
              tenant_id: caller.tenant_id, user_id: r.user_id, challenge: type,
              level: st.level, baseline: st.baseline, target,
              metric_value: metric, active_days: activeDays, suspicious,
              status: 'rewarded', reviewed_at: new Date().toISOString(),
            });
            if (insErr && !/duplicate|unique|23505/i.test(insErr.message || '')) {
              app.log.warn(`[challenge] no se pudo crear claim: ${insErr.message}`);
            }
          }
          challenges.push({
            type, level: st.level, target, progress,
            remaining: Math.max(0, target - progress),
            pct: target > 0 ? Math.min(1, progress / target) : 0,
            reached, pending: st.pending, rejected: st.rejected,
          });
        }
        // NOTA: el aviso anti-fraude (salto de km / carrera enorme) ya NO se
        // envía al jefe; se marca en el claim y lo revisa el admin.
        drivers.push({
          user_id: r.user_id, name: r.name, email: r.email,
          challenges,
        });
      }
      return reply.send({ drivers });
    } catch (e) {
      request.log.error(e);
      return reply.code(500).send({ error: 'No se pudieron calcular los retos' });
    }
  });

  // Loop #6: retos del PROPIO conductor (para que los vea en su app). Devuelve su
  // progreso por reto (km / días), con nivel y objetivo actuales.
  app.get('/api/v1/challenges/mine', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    try {
      const { base, levelMultiplier, levelCycle } = await challengeConfig();
      const { data: stats } = await supabase.rpc('challenge_stats', { p_user: caller.id });
      const row = Array.isArray(stats) ? (stats[0] ?? {}) : (stats ?? {});
      const metrics = {
        km_100k: Number(row.km ?? 0),
        money_100k: Number(row.money ?? 0),
        days_300: Number(row.active_days ?? 0),
      };
      const { data: claims } = await supabase.from('challenge_claims')
        .select('challenge, level, metric_value, status').eq('user_id', caller.id);
      const byChal = {};
      for (const c of claims ?? []) (byChal[c.challenge] ??= []).push(c);
      const challenges = [];
      for (const type of Object.keys(base)) {
        const st = levelState(byChal[type] ?? []);
        const target = incrementFor(base, type, st.level, levelMultiplier, levelCycle);
        const metric = metrics[type];
        const progress = Math.max(0, metric - st.baseline);
        challenges.push({
          type, level: st.level, target, progress,
          remaining: Math.max(0, target - progress),
          pct: target > 0 ? Math.min(1, progress / target) : 0,
          reached: progress >= target,
        });
      }
      return reply.send({ challenges });
    } catch (e) {
      request.log.error(e);
      return reply.code(500).send({ error: 'No se pudieron calcular tus retos' });
    }
  });

  // Estado del claim normalizado a la nomenclatura del dashboard. Loop #4 hace
  // que los logros se auto-registren como 'rewarded' (=approved); 'pending' es
  // legado (ya no se genera). 'rejected' = rechazado por fraude.
  const challengeStatusLabel = (s) =>
    s === 'rewarded' ? 'approved' : (s === 'rejected' ? 'rejected' : 'pending');

  // Admin: lista de retos (de todas las empresas) con nivel, último reto
  // completado y estado normalizado. Filtros: ?level= y ?status=.
  app.get('/api/v1/admin/challenges', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { data, error } = await supabase
      .from('challenge_claims')
      .select('id, user_id, tenant_id, challenge, level, target, baseline, metric_value, active_days, '
        + 'suspicious, status, created_at, reviewed_at, users:user_id(email, name), tenants:tenant_id(name)')
      .order('created_at', { ascending: false });
    if (error) return reply.code(500).send({ error: error.message });

    // Último reto completado (rewarded) por conductor, para mostrarlo en cada fila.
    const lastCompletedByUser = {};
    for (const r of data ?? []) {
      if (r.status === 'rewarded' && r.reviewed_at) {
        const cur = lastCompletedByUser[r.user_id];
        if (!cur || new Date(r.reviewed_at) > new Date(cur)) lastCompletedByUser[r.user_id] = r.reviewed_at;
      }
    }

    let rows = (data ?? []).map((r) => ({
      ...r,
      status_label: challengeStatusLabel(r.status),
      last_completed: lastCompletedByUser[r.user_id] ?? null,
      // Loop #6: el anti-fraude lo revisa el admin. `suspicious` viene marcado en
      // el claim cuando el logro tuvo un salto de km / carrera enorme.
      suspicious: r.suspicious === true,
    }));

    const fLevel = request.query?.level;
    if (fLevel != null && fLevel !== '') {
      const lvl = parseInt(fLevel, 10);
      rows = rows.filter((r) => (r.level ?? 0) === lvl);
    }
    const fStatus = request.query?.status;
    if (fStatus) rows = rows.filter((r) => r.status_label === fStatus);

    return reply.send({ claims: rows });
  });

  // Admin: KPIs de super retos (resumen global).
  app.get('/api/v1/admin/challenges/summary', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { data: claims } = await supabase.from('challenge_claims')
      .select('user_id, level, status, created_at, reviewed_at').limit(20000);
    const { count: totalDrivers } = await supabase.from('users')
      .select('id', { count: 'exact', head: true }).eq('role', 'driver');

    const now = new Date();
    const dayMs = 86400000;
    const monthStart = new Date(now.getUTCFullYear(), now.getUTCMonth(), 1).getTime();
    // Serie diaria de retos completados (últimos 30 días), por fecha ISO.
    const daily = {};
    for (let i = 29; i >= 0; i--) {
      const d = new Date(now.getTime() - i * dayMs).toISOString().slice(0, 10);
      daily[d] = 0;
    }

    let totalCompleted = 0;
    let pendingApprovals = 0;
    let rejected = 0;
    let completedThisMonth = 0;
    const driversWithClaim = new Set();
    const maxLevelByUser = {};        // nivel máximo aprobado por conductor
    for (const c of claims ?? []) {
      driversWithClaim.add(c.user_id);
      if (c.status === 'rewarded') {
        totalCompleted += 1;
        const lvl = c.level ?? 1;
        if (!maxLevelByUser[c.user_id] || lvl > maxLevelByUser[c.user_id]) maxLevelByUser[c.user_id] = lvl;
        const when = c.reviewed_at || c.created_at;
        if (when) {
          const t = new Date(when).getTime();
          if (t >= monthStart) completedThisMonth += 1;
          const key = new Date(when).toISOString().slice(0, 10);
          if (key in daily) daily[key] += 1;
        }
      } else if (c.status === 'pending') {
        pendingApprovals += 1;
      } else if (c.status === 'rejected') {
        rejected += 1;
      }
    }
    const levels = Object.values(maxLevelByUser);
    const avgLevel = levels.length ? +(levels.reduce((s, n) => s + n, 0) / levels.length).toFixed(1) : 0;
    const driversWithChallenge = totalDrivers
      ? +((driversWithClaim.size / totalDrivers) * 100).toFixed(1) : 0;
    // Tasa de fraude = rechazados / (completados + rechazados).
    const fraudRate = (totalCompleted + rejected) > 0
      ? +((rejected / (totalCompleted + rejected)) * 100).toFixed(1) : 0;

    // Días gratis concedidos por retos = suma de las extensiones de suscripción
    // (cada reto completado = 1 mes gratis / 30 días).
    const { data: extRows } = await supabase.from('subscription_extensions')
      .select('days_extended').eq('extension_type', 'challenge').limit(20000);
    const daysChallenges = (extRows ?? [])
      .reduce((s, r) => s + (r.days_extended ?? 0), 0);

    return reply.send({
      total_completed: totalCompleted,
      drivers_with_challenge: driversWithChallenge, // %
      avg_level: avgLevel,
      days_challenges: daysChallenges,
      pending_approvals: pendingApprovals,
      rejected,
      fraud_rate: fraudRate, // %
      completed_this_month: completedThisMonth,
      daily: Object.entries(daily).map(([date, count]) => ({ date, count })),
    });
  });

  // Admin: detalle ampliado de un reto -> historial completo del conductor,
  // niveles actuales por reto y comparativa con la media de su flota.
  app.get('/api/v1/admin/challenges/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { data: claim } = await supabase.from('challenge_claims')
      .select('id, user_id, tenant_id, challenge, level, status, created_at, reviewed_at, '
        + 'users:user_id(email, name), tenants:tenant_id(name)')
      .eq('id', request.params.id).maybeSingle();
    if (!claim) return reply.code(404).send({ error: 'Reto no encontrado' });

    // Historial completo del conductor (todos sus claims, ordenados).
    const { data: history } = await supabase.from('challenge_claims')
      .select('id, challenge, level, target, baseline, metric_value, status, created_at, reviewed_at')
      .eq('user_id', claim.user_id)
      .order('created_at', { ascending: true });

    // Niveles actuales por reto (derivados de los claims rewarded).
    const byChal = {};
    for (const c of history ?? []) ((byChal[c.challenge] ??= []).push(c));
    const currentLevels = {};
    const { base } = await challengeConfig();
    for (const type of Object.keys(base)) {
      currentLevels[type] = levelState(byChal[type] ?? []).level;
    }

    // Comparativa con la flota: nivel máximo aprobado medio en el mismo tenant.
    const { data: tenantClaims } = await supabase.from('challenge_claims')
      .select('user_id, level, status').eq('tenant_id', claim.tenant_id).eq('status', 'rewarded').limit(20000);
    const maxByUser = {};
    for (const c of tenantClaims ?? []) {
      if (!maxByUser[c.user_id] || (c.level ?? 1) > maxByUser[c.user_id]) maxByUser[c.user_id] = c.level ?? 1;
    }
    const vals = Object.values(maxByUser);
    const fleetAvgLevel = vals.length ? +(vals.reduce((s, n) => s + n, 0) / vals.length).toFixed(1) : 0;

    // PROTECCIÓN DE DATOS: en el reto de dinero (money_100k) las métricas son
    // euros de la empresa -> se enmascaran para el admin (no ve importes).
    const maskMoney = (h) => (h.challenge === 'money_100k'
      ? { ...h, metric_value: null, target: null, baseline: null, money_masked: true }
      : h);
    return reply.send({
      claim,
      driver_history: (history ?? []).map((h) =>
        ({ ...maskMoney(h), status_label: challengeStatusLabel(h.status) })),
      current_levels: currentLevels,
      fleet_avg_level: fleetAvgLevel,
    });
  });

  // Admin: forzar la finalización (aprobación) de un reto. Requiere justificación
  // (reason) y queda registrado en auditoría. No extiende suscripción (Loop #4).
  app.post('/api/v1/admin/challenges/:id/force-complete', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const reason = (request.body ?? {}).reason;
    if (!reason || !String(reason).trim()) {
      return reply.code(400).send({ error: 'Se requiere una justificación (reason)' });
    }
    const { data: claim } = await supabase.from('challenge_claims')
      .select('id, user_id, status').eq('id', request.params.id).maybeSingle();
    if (!claim) return reply.code(404).send({ error: 'Reto no encontrado' });
    await supabase.from('challenge_claims')
      .update({ status: 'rewarded', reviewed_at: new Date().toISOString() }).eq('id', claim.id);
    await logAdminAction(request, g.caller.id, 'challenge_force_complete', 'challenge', claim.id,
      { reason: String(reason), previous_status: claim.status });
    return reply.send({ ok: true });
  });

  // ============================================================
  // Loop #5 — Centro de fraude (unifica referral_fraud_alerts + fraud_alerts)
  // y logs de auditoría. Solo admin. El id unificado es "<source>:<uuid>".
  // ============================================================

  // Normaliza una alerta de referidos al formato genérico del centro de fraude.
  const mapReferralAlert = (a) => ({
    alert_id: `referral:${a.id}`, source: 'referral', id: a.id,
    alert_type: a.type, severity: a.severity, status: a.status,
    description: null, evidence: a.detail ?? null,
    referral_id: a.referral_id, tenant_id: null, user_id: null,
    created_at: a.created_at, resolved_at: a.resolved_at ?? null,
  });
  const mapGenericAlert = (a) => ({
    alert_id: `fraud:${a.id}`, source: 'fraud', id: a.id,
    alert_type: a.alert_type, severity: a.severity, status: a.status,
    description: a.description, evidence: a.evidence ?? null,
    referral_id: null, tenant_id: a.tenant_id, user_id: a.user_id,
    resolution_notes: a.resolution_notes ?? null,
    created_at: a.created_at, resolved_at: a.resolved_at ?? null,
  });

  // Lista unificada de alertas. Filtros: ?severity= &status= &type= &source=.
  app.get('/api/v1/admin/fraud/alerts', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const qp = request.query ?? {};
    const limit = Math.min(Math.max(parseInt(qp.limit ?? '50', 10) || 50, 1), 200);
    const offset = Math.max(parseInt(qp.offset ?? '0', 10) || 0, 0);
    const wantReferral = !qp.source || qp.source === 'referral';
    const wantGeneric = !qp.source || qp.source === 'fraud';

    let items = [];
    if (wantReferral) {
      let rq = supabase.from('referral_fraud_alerts')
        .select('id, referral_id, type, severity, status, detail, created_at, resolved_at')
        .order('created_at', { ascending: false }).limit(1000);
      if (qp.severity) rq = rq.eq('severity', qp.severity);
      if (qp.status) rq = rq.eq('status', qp.status);
      if (qp.type) rq = rq.eq('type', qp.type);
      const { data } = await rq;
      items = items.concat((data ?? []).map(mapReferralAlert));
    }
    if (wantGeneric) {
      let fq = supabase.from('fraud_alerts')
        .select('id, tenant_id, user_id, alert_type, severity, description, evidence, status, '
          + 'resolution_notes, created_at, resolved_at')
        .order('created_at', { ascending: false }).limit(1000);
      if (qp.severity) fq = fq.eq('severity', qp.severity);
      if (qp.status) fq = fq.eq('status', qp.status);
      if (qp.type) fq = fq.eq('alert_type', qp.type);
      const { data } = await fq;
      items = items.concat((data ?? []).map(mapGenericAlert));
    }
    items.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
    const total = items.length;
    return reply.send({ alerts: items.slice(offset, offset + limit), total, limit, offset });
  });

  // Detalle de una alerta unificada ("<source>:<uuid>").
  app.get('/api/v1/admin/fraud/alerts/:aid', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const [source, id] = String(request.params.aid).split(':');
    if (source === 'referral') {
      const { data: a } = await supabase.from('referral_fraud_alerts')
        .select('id, referral_id, type, severity, status, detail, created_at, resolved_at')
        .eq('id', id).maybeSingle();
      if (!a) return reply.code(404).send({ error: 'Alerta no encontrada' });
      return reply.send({ alert: mapReferralAlert(a) });
    }
    if (source === 'fraud') {
      const { data: a } = await supabase.from('fraud_alerts')
        .select('id, tenant_id, user_id, alert_type, severity, description, evidence, status, '
          + 'resolution_notes, resolved_by, created_at, resolved_at')
        .eq('id', id).maybeSingle();
      if (!a) return reply.code(404).send({ error: 'Alerta no encontrada' });
      return reply.send({ alert: mapGenericAlert(a) });
    }
    return reply.code(400).send({ error: 'Identificador de alerta no válido' });
  });

  // Resolver una alerta con notas. body: { notes?, status? }.
  app.put('/api/v1/admin/fraud/alerts/:aid/resolve', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const b = request.body ?? {};
    const notes = b.notes ?? null;
    const [source, id] = String(request.params.aid).split(':');
    const nowIso = new Date().toISOString();
    if (source === 'referral') {
      // Conserva las notas dentro de detail (la tabla no tiene columna de notas).
      const { data: a } = await supabase.from('referral_fraud_alerts')
        .select('detail').eq('id', id).maybeSingle();
      if (!a) return reply.code(404).send({ error: 'Alerta no encontrada' });
      const detail = { ...(a.detail ?? {}), resolution_notes: notes };
      await supabase.from('referral_fraud_alerts')
        .update({ status: 'resolved', resolved_at: nowIso, detail }).eq('id', id);
    } else if (source === 'fraud') {
      const status = ['investigating', 'resolved'].includes(b.status) ? b.status : 'resolved';
      await supabase.from('fraud_alerts').update({
        status, resolution_notes: notes,
        resolved_by: g.caller.id, resolved_at: status === 'resolved' ? nowIso : null,
      }).eq('id', id);
    } else {
      return reply.code(400).send({ error: 'Identificador de alerta no válido' });
    }
    await logAdminAction(request, g.caller.id, 'fraud_alert_resolve', 'fraud_alert', request.params.aid,
      { notes });
    return reply.send({ ok: true });
  });

  // Logs de auditoría de acciones administrativas. Filtros: ?action_type= &admin_id=.
  app.get('/api/v1/admin/audit/logs', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const qp = request.query ?? {};
    const limit = Math.min(Math.max(parseInt(qp.limit ?? '50', 10) || 50, 1), 200);
    const offset = Math.max(parseInt(qp.offset ?? '0', 10) || 0, 0);
    let q = supabase.from('admin_actions_log')
      .select('id, admin_id, action_type, target_type, target_id, details, ip_address, created_at, '
        + 'admin:admin_id(email, name)', { count: 'exact' })
      .order('created_at', { ascending: false });
    if (qp.action_type) q = q.eq('action_type', qp.action_type);
    if (qp.admin_id) q = q.eq('admin_id', qp.admin_id);
    const { data, count, error } = await q.range(offset, offset + limit - 1);
    if (error) return reply.code(500).send({ error: error.message });
    return reply.send({ logs: data ?? [], total: count ?? (data ?? []).length, limit, offset });
  });

  // Admin: revisar un reto. Loop #4: la recompensa individual (mes gratis por
  // claim) está DESACTIVADA — los días gratis se reparten trimestralmente por %
  // de flota (cron). 'reject' sigue activo como control de FRAUDE: un claim
  // rechazado no cuenta en la métrica trimestral (drivers_with_achievement). La
  // acción 'reward' se conserva por compatibilidad pero ya NO extiende ninguna
  // suscripción (los retos se auto-registran como 'rewarded' al alcanzarse).
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

    // Sin extensión de suscripción aquí (deprecado en Loop #4).
    await supabase.from('challenge_claims')
      .update({ status: action === 'reward' ? 'rewarded' : 'rejected', reviewed_at: new Date().toISOString() })
      .eq('id', claim.id);
    return reply.send({ ok: true, note: 'reward individual deprecado; recompensa trimestral por flota' });
  });

  // Rate limiter básico en memoria (sin dependencias): N peticiones por ventana
  // y clave. Devuelve true si la petición debe bloquearse (límite superado).
  const _rlBuckets = new Map();
  function rateLimited(key, max = 100, windowMs = 60000) {
    const now = Date.now();
    const b = _rlBuckets.get(key);
    if (!b || now > b.reset) {
      _rlBuckets.set(key, { count: 1, reset: now + windowMs });
      return false;
    }
    b.count += 1;
    return b.count > max;
  }

  // JEFE: días gratis conseguidos con RETOS y REFERIDOS (el "ahorro" del nuevo
  // modelo: cada reto o referido validado extiende la suscripción). Devuelve el
  // total por retos/referidos y el detalle de cada extensión. Solo owner (o
  // admin con ?tenant_id=).
  app.get('/api/v1/tenant/free-days', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (caller.role !== 'owner' && !caller.is_admin) {
      return reply.code(403).send({ error: 'Solo el propietario o el admin' });
    }
    if (rateLimited(`fd:${caller.id}`)) {
      return reply.code(429).send({ error: 'Demasiadas peticiones, prueba en un minuto' });
    }
    const tenantId = (caller.is_admin && request.query?.tenant_id)
      ? request.query.tenant_id : caller.tenant_id;
    const totals = await freeDaysForTenant(tenantId);

    // Detalle de retos: cada extensión con su fecha y días.
    const { data: exts } = await supabase.from('subscription_extensions')
      .select('days_extended, applied_at, extension_type')
      .eq('tenant_id', tenantId).eq('extension_type', 'challenge')
      .order('applied_at', { ascending: false }).limit(100);
    // Detalle de referidos: hitos conseguidos por los owners del tenant.
    const { data: owners } = await supabase.from('users')
      .select('id').eq('tenant_id', tenantId).eq('role', 'owner');
    const ownerIds = (owners ?? []).map((o) => o.id);
    let milestones = [];
    if (ownerIds.length) {
      const { data: rr } = await supabase.from('referral_milestone_rewards')
        .select('milestone_level, days_awarded, created_at').in('user_id', ownerIds)
        .order('created_at', { ascending: false }).limit(100);
      milestones = rr ?? [];
    }
    return reply.send({
      challenges_days: totals.challenges,
      referrals_days: totals.referrals,
      total_days: totals.total,
      challenge_extensions: exts ?? [],
      referral_milestones: milestones,
    });
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

  // ¿Puede invitar? Owner/autónomo con suscripción activa de pago
  // o en periodo de prueba todavía vigente.
  async function isReferralEligible(caller) {
    if (!caller || caller.role !== 'owner' || !caller.tenant_id) return false;
    const { data: t } = await supabase
      .from('tenants').select('subscription_status, trial_ends_at')
      .eq('id', caller.tenant_id).maybeSingle();
    if (!t) return false;
    if (t.subscription_status === 'active' || t.subscription_status === 'past_due') return true;
    const trialVigente = t.trial_ends_at && new Date() < new Date(t.trial_ends_at);
    return trialVigente === true;
  }

  // Devuelve el código del usuario; si no tiene, genera uno único "TX"+6.
  async function ensureReferralCode(userId) {
    const { data: existing } = await supabase
      .from('referral_codes').select('code').eq('user_id', userId).maybeSingle();
    if (existing) return existing.code;
    const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    // Aleatoriedad criptográfica (evita predicción/colisión de Math.random).
    // Rechazo de bytes >= 256 - (256 % len) para no introducir sesgo de módulo.
    const pickChar = () => {
      const max = 256 - (256 % ALPHABET.length);
      let b;
      do { b = randomBytes(1)[0]; } while (b >= max);
      return ALPHABET[b % ALPHABET.length];
    };
    for (let i = 0; i < 6; i++) {
      const code = 'TX' + Array.from({ length: 6 }, pickChar).join('');
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
        validation_days: parseInt(cfg.referral_pay_window_days ?? '15', 10),
      });
    } catch (e) {
      request.log.error(e);
      return reply.code(500).send({ error: 'No se pudo obtener el código' });
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
    const milestonesAchieved = (rewardRows ?? []).length;
    const { count: openAlerts } = await supabase.from('referral_fraud_alerts')
      .select('id', { count: 'exact', head: true }).eq('status', 'open');
    return reply.send({
      total, pending, valid, reverted, rejected,
      total_referrals: total,                                          // alias spec
      shares_total: sharesTotal ?? 0,
      conversion_rate: total ? +(valid / total).toFixed(3) : 0,        // válidos / total
      cpa_days: valid ? +(daysAwarded / valid).toFixed(1) : 0,         // días gratis por adquisición
      k_factor: distinctReferrers ? +(valid / distinctReferrers).toFixed(2) : 0, // válidos por referidor
      milestones_achieved: milestonesAchieved,
      days_awarded: daysAwarded,
      open_alerts: openAlerts ?? 0,
      fraud_alerts: openAlerts ?? 0,                                   // alias spec
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

  // Editar la configuración del programa (claves referral_* y challenge_*).
  app.put('/api/v1/admin/referrals/config', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const body = request.body ?? {};
    const updates = Object.entries(body)
      .filter(([k]) => k.startsWith('referral_') || k.startsWith('challenge_') || k.startsWith('maintenance_'));
    if (!updates.length) return reply.code(400).send({ error: 'Nada que actualizar (claves referral_*/challenge_*/maintenance_*)' });
    for (const [key, value] of updates) {
      await supabase.from('system_config')
        .upsert({ key, value: String(value), updated_at: new Date().toISOString() }, { onConflict: 'key' });
    }
    await logAdminAction(request, g.caller.id, 'referral_config_update', 'config', 'system_config',
      { changes: Object.fromEntries(updates.map(([k, v]) => [k, String(v)])) });
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
  // Loop #5 — Dashboard de Super Admin: referidos (listado con filtros,
  // detalle, bloqueo/desbloqueo, config con auditoría). Solo admin.
  // Nota de reconciliación: los estados reales del modelo son
  // pending|valid|reverted|rejected (el spec citaba clicked/registered/...);
  // aceptamos también el alias 'validated' -> 'valid'. La config vive en
  // system_config (no se crea una tabla paralela global_referral_config).
  // ============================================================
  const REF_STATUSES = ['pending', 'valid', 'reverted', 'rejected'];

  // Listado de referidos con filtros y paginación. Filtros: tenant_id, status
  // (CSV), date_from/date_to (created_at), channel (canal de compartición del
  // referidor), search (email/nombre de referidor o referido).
  app.get('/api/v1/admin/referrals/list', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const qp = request.query ?? {};
    const limit = Math.min(Math.max(parseInt(qp.limit ?? '25', 10) || 25, 1), 100);
    const offset = Math.max(parseInt(qp.offset ?? '0', 10) || 0, 0);

    let q = supabase.from('referrals')
      .select('id, status, created_at, validated_at, reverted_at, signup_ip, signup_device_id, '
        + 'referred_tenant_id, referrer:referrer_user_id(id, email, name), '
        + 'referred:referred_user_id(id, email, name), tenant:referred_tenant_id(name)',
        { count: 'exact' })
      .order('created_at', { ascending: false });

    if (qp.tenant_id) q = q.eq('referred_tenant_id', qp.tenant_id);
    if (qp.status) {
      const arr = String(qp.status).split(',').map((s) => s.trim())
        .map((s) => (s === 'validated' ? 'valid' : s))
        .filter((s) => REF_STATUSES.includes(s));
      if (arr.length) q = q.in('status', arr);
    }
    if (qp.date_from) q = q.gte('created_at', qp.date_from);
    if (qp.date_to) q = q.lte('created_at', qp.date_to);
    if (qp.channel) {
      const { data: sh } = await supabase.from('referral_shares')
        .select('user_id').eq('channel', qp.channel).limit(5000);
      const ids = [...new Set((sh ?? []).map((r) => r.user_id))];
      if (!ids.length) return reply.send({ referrals: [], total: 0, limit, offset });
      q = q.in('referrer_user_id', ids);
    }
    if (qp.search) {
      const term = `%${String(qp.search).trim()}%`;
      const { data: us } = await supabase.from('users')
        .select('id').or(`email.ilike.${term},name.ilike.${term}`).limit(5000);
      const ids = [...new Set((us ?? []).map((u) => u.id))];
      if (!ids.length) return reply.send({ referrals: [], total: 0, limit, offset });
      const list = ids.join(',');
      q = q.or(`referrer_user_id.in.(${list}),referred_user_id.in.(${list})`);
    }

    const { data: refs, count, error } = await q.range(offset, offset + limit - 1);
    if (error) return reply.code(500).send({ error: error.message });

    // Alertas abiertas por referral (para marcar sospechosos en la lista).
    const ids = (refs ?? []).map((r) => r.id);
    let byRef = {};
    if (ids.length) {
      const { data: alerts } = await supabase.from('referral_fraud_alerts')
        .select('id, referral_id, type, severity, status').eq('status', 'open').in('referral_id', ids);
      for (const a of alerts ?? []) (byRef[a.referral_id] ??= []).push(a);
    }
    const rows = (refs ?? []).map((r) => ({ ...r, alerts: byRef[r.id] ?? [] }));
    return reply.send({ referrals: rows, total: count ?? rows.length, limit, offset });
  });

  // Configuración de parámetros (lectura). Devuelve las claves referral_* y
  // challenge_* (el panel de admin edita ambas) y los hitos ya parseados.
  app.get('/api/v1/admin/referrals/config', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const cfg = await refConfig();
    const config = Object.fromEntries(Object.entries(cfg)
      .filter(([k]) => k.startsWith('referral_') || k.startsWith('challenge_')));
    return reply.send({ config, milestones: milestonesFrom(cfg) });
  });

  // Detalle de un referido: referidor, invitado, empresa, historial y fraude.
  app.get('/api/v1/admin/referrals/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { data: ref, error } = await supabase.from('referrals')
      .select('id, status, created_at, validated_at, reverted_at, signup_ip, signup_device_id, '
        + 'referred_tenant_id, referrer:referrer_user_id(id, email, name, tenant_id), '
        + 'referred:referred_user_id(id, email, name), '
        + 'tenant:referred_tenant_id(name, plan_id, subscription_status, created_at)')
      .eq('id', request.params.id).maybeSingle();
    if (error) return reply.code(500).send({ error: error.message });
    if (!ref) return reply.code(404).send({ error: 'Referido no encontrado' });

    // Hitos del referidor (ledger) + alertas de fraude de este referido.
    const referrerId = ref.referrer?.id;
    const [{ data: milestones }, { data: alerts }] = await Promise.all([
      referrerId
        ? supabase.from('referral_milestone_rewards')
            .select('milestone_level, required, days_awarded, awarded_at')
            .eq('user_id', referrerId).order('milestone_level', { ascending: true })
        : Promise.resolve({ data: [] }),
      supabase.from('referral_fraud_alerts')
        .select('id, type, severity, status, detail, created_at, resolved_at')
        .eq('referral_id', ref.id).order('created_at', { ascending: false }),
    ]);

    // Historial de eventos derivado de los timestamps.
    const events = [{ type: 'created', at: ref.created_at }];
    if (ref.validated_at) events.push({ type: 'validated', at: ref.validated_at });
    if (ref.reverted_at) events.push({ type: 'reverted', at: ref.reverted_at });
    for (const m of milestones ?? []) {
      events.push({ type: 'milestone', at: m.awarded_at, level: m.milestone_level, days: m.days_awarded });
    }
    events.sort((a, b) => new Date(a.at) - new Date(b.at));

    return reply.send({
      referral: ref,
      referrer_milestones: milestones ?? [],
      fraud: {
        signup_ip: ref.signup_ip,
        signup_device_id: ref.signup_device_id,
        alerts: alerts ?? [],
      },
      events,
    });
  });

  // Bloquear un referido por fraude: pasa a 'rejected' y se revierten sus
  // recompensas automáticamente (recompute revoca los hitos que ya no apliquen).
  app.put('/api/v1/admin/referrals/:id/block', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const reason = (request.body ?? {}).reason ?? null;
    const { data: ref } = await supabase.from('referrals')
      .select('id, referrer_user_id, status').eq('id', request.params.id).maybeSingle();
    if (!ref) return reply.code(404).send({ error: 'Referido no encontrado' });
    await supabase.from('referrals')
      .update({ status: 'rejected', reverted_at: new Date().toISOString() }).eq('id', ref.id);
    await recomputeReferrerMilestones(ref.referrer_user_id); // clawback automático
    await createFraudAlert(ref.id, 'manual_block', 'high', { reason, by: g.caller.id });
    await logAdminAction(request, g.caller.id, 'referral_block', 'referral', ref.id,
      { reason, previous_status: ref.status });
    return reply.send({ ok: true });
  });

  // Desbloquear un referido: restaura su estado (valid si llegó a validarse, o
  // pending) y recalcula hitos. Descarta sus alertas abiertas.
  app.put('/api/v1/admin/referrals/:id/unblock', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { data: ref } = await supabase.from('referrals')
      .select('id, referrer_user_id, status, validated_at').eq('id', request.params.id).maybeSingle();
    if (!ref) return reply.code(404).send({ error: 'Referido no encontrado' });
    const restored = ref.validated_at ? 'valid' : 'pending';
    await supabase.from('referrals')
      .update({ status: restored, reverted_at: null }).eq('id', ref.id);
    await recomputeReferrerMilestones(ref.referrer_user_id);
    await supabase.from('referral_fraud_alerts')
      .update({ status: 'dismissed', resolved_at: new Date().toISOString() })
      .eq('referral_id', ref.id).eq('status', 'open');
    await logAdminAction(request, g.caller.id, 'referral_unblock', 'referral', ref.id,
      { restored_status: restored, previous_status: ref.status });
    return reply.send({ ok: true, status: restored });
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

    // Los días solo se conceden si el referidor ya es cliente DE PAGO. En prueba
    // se difieren: al pasar a suscripción (webhook) se vuelve a recalcular y se
    // conceden los hitos pendientes.
    const { data: refUser } = await supabase.from('users')
      .select('tenant_id').eq('id', referrerUserId).maybeSingle();
    const paying = refUser?.tenant_id ? await tenantIsPaying(refUser.tenant_id) : false;

    // Conceder hitos alcanzados que aún no se hayan concedido (solo si de pago).
    for (const m of milestones) {
      if (target.has(m.level) && !claimed.has(m.level) && paying) {
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
    // Cancelación dentro de la gracia -> 'rejected' (según spec); reverted_at deja
    // constancia de que fue por cancelación. recompute revoca el hito (clawback).
    await supabase.from('referrals')
      .update({ status: 'rejected', reverted_at: new Date().toISOString() }).eq('id', ref.id);
    await recomputeReferrerMilestones(ref.referrer_user_id);
  }

  // ==========================================================================
  // Validación de referidos a 15 días desde el PRIMER PAGO (unificada con los
  // hitos). Al pagar el invitado NO se premia aún: se encola. A los 15 días, si
  // sigue de alta, el referido pasa a 'valid' y se recalculan los HITOS del
  // referidor, que le conceden los DÍAS gratis según su nº de referidos válidos.
  // ==========================================================================

  // Ventana de validación en días (desde el primer pago del referido).
  async function referralPayWindowDays() {
    const cfg = await refConfig();
    return parseInt(cfg.referral_pay_window_days ?? '15', 10);
  }

  // Primer pago del referido -> fija first_payment_date (si no estaba) y encola
  // la validación a +N días. Idempotente: no re-encola si ya hay una entrada
  // sin procesar, ni toca referidos que no estén 'pending'.
  async function enqueueReferralValidation(tenantId) {
    if (!tenantId) return;
    const { data: ref } = await supabase.from('referrals')
      .select('id, validation_status, first_payment_date')
      .eq('referred_tenant_id', tenantId).maybeSingle();
    if (!ref || ref.validation_status !== 'pending') return;

    const nowIso = new Date().toISOString();
    const firstPay = ref.first_payment_date ?? nowIso;
    if (!ref.first_payment_date) {
      await supabase.from('referrals')
        .update({ first_payment_date: firstPay }).eq('id', ref.id);
    }
    // ¿Ya hay una validación pendiente en la cola? -> no duplicar.
    const { data: pend } = await supabase.from('referral_validation_queue')
      .select('id').eq('referral_id', ref.id).eq('processed', false).maybeSingle();
    if (pend) return;

    const days = await referralPayWindowDays();
    const scheduledFor = new Date(new Date(firstPay).getTime() + days * 86400000).toISOString();
    await supabase.from('referral_validation_queue')
      .insert({ referral_id: ref.id, scheduled_for: scheduledFor });
    app.log.info(`[referral-v8] encolada validación de ${ref.id} para ${scheduledFor}`);
  }

  // Cancelación mientras la validación aún está pendiente -> se rechaza y se
  // marca la cola como procesada (ya no hay nada que validar).
  async function rejectPendingReferralValidation(tenantId) {
    if (!tenantId) return;
    const { data: ref } = await supabase.from('referrals')
      .select('id, validation_status')
      .eq('referred_tenant_id', tenantId).maybeSingle();
    if (!ref || ref.validation_status !== 'pending') return;
    await supabase.from('referrals')
      .update({ validation_status: 'rejected', validation_date: new Date().toISOString() })
      .eq('id', ref.id);
    await supabase.from('referral_validation_queue')
      .update({ processed: true }).eq('referral_id', ref.id).eq('processed', false);
    app.log.info(`[referral-v8] validación de ${ref.id} rechazada por cancelación`);
  }

  // ¿La empresa referida sigue siendo cliente de pago?
  async function tenantSubscriptionActive(tenantId) {
    const { data: t } = await supabase.from('tenants')
      .select('subscription_status').eq('id', tenantId).maybeSingle();
    return ['active', 'past_due', 'trialing'].includes(t?.subscription_status);
  }

  // Cron diario: procesa las validaciones vencidas (15 días desde el 1er pago).
  // Si el invitado sigue de alta -> el referido pasa a 'valid' y se recalculan
  // los HITOS del referidor (días gratis según su nº de referidos válidos). Si
  // canceló -> 'rejected'. Marca la cola como procesada.
  async function processReferralValidationQueue() {
    const nowIso = new Date().toISOString();
    const { data: due } = await supabase.from('referral_validation_queue')
      .select('id, referral_id, referrals:referral_id(id, referred_tenant_id, validation_status, referrer_user_id)')
      .eq('processed', false).lte('scheduled_for', nowIso).limit(500);
    let validated = 0;
    let rejected = 0;
    for (const q of due ?? []) {
      const ref = q.referrals;
      if (!ref || ref.validation_status !== 'pending') {
        // Ya resuelto por otra vía (p. ej. cancelación): solo cerrar la cola.
        await supabase.from('referral_validation_queue').update({ processed: true }).eq('id', q.id);
        continue;
      }
      const active = await tenantSubscriptionActive(ref.referred_tenant_id);
      if (active) {
        // Validado: el referido cuenta como 'valid' y se recalculan los hitos
        // del referidor, que le conceden los días gratis correspondientes.
        await supabase.from('referrals').update({
          status: 'valid', validated_at: nowIso,
          validation_status: 'validated', validation_date: nowIso,
        }).eq('id', ref.id);
        try {
          await recomputeReferrerMilestones(ref.referrer_user_id);
        } catch (e) {
          app.log.warn(`[referral] hitos de ${ref.id}: ${e.message}`);
        }
        if (ref.referrer_user_id) {
          await notifyUser(ref.referrer_user_id, '🎉 ¡Invitación validada!',
            'Tu invitado sigue de alta tras 15 días. Revisa tus días gratis por referidos.',
            { type: 'referral_validated' });
        }
        validated++;
      } else {
        await supabase.from('referrals').update({
          status: 'rejected', validation_status: 'rejected', validation_date: nowIso,
        }).eq('id', ref.id);
        rejected++;
      }
      await supabase.from('referral_validation_queue').update({ processed: true }).eq('id', q.id);
    }
    return { processed: (due ?? []).length, validated, rejected };
  }

  app.post('/api/v1/admin/cron/process-referral-validations', async (request, reply) => {
    const g = await cronOrAdmin(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const res = await processReferralValidationQueue();
    await markCronRun('referral_validations');
    await logAdminAction(request, g.caller?.id ?? null, 'referral_validations_process', 'referral_validation_queue', null, res);
    return reply.send({ ok: true, ...res });
  });

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
      // Programa de referidos: al PAGAR el invitado NO se premia aún; se encola
      // la validación a +15 días (si sigue de alta, gana los días por hitos).
      // Al CANCELAR: se rechaza la validación pendiente y se revierten (clawback)
      // los días si ya se habían concedido.
      if (result.handled && result.tenant_id) {
        try {
          if (result.type === 'checkout.session.completed' || result.type === 'invoice.paid') {
            await enqueueReferralValidation(result.tenant_id);
            // Si este tenant es un REFERIDOR que tenía hitos diferidos (estaba
            // en prueba), ahora que paga se le conceden los días pendientes.
            const { data: owner } = await supabase.from('users')
              .select('id').eq('tenant_id', result.tenant_id).eq('role', 'owner').maybeSingle();
            if (owner?.id) await recomputeReferrerMilestones(owner.id);
          } else if (result.type === 'customer.subscription.deleted') {
            await rejectPendingReferralValidation(result.tenant_id);
            await revertReferralForTenant(result.tenant_id); // clawback de días si ya validado
          }
        } catch (e) {
          request.log.error(`[referral] ${e.message}`);
        }
      }
      return reply.send({ received: true, ...result });
    } catch (e) {
      request.log.error(e);
      return reply.code(500).send({ error: 'Error procesando el evento' });
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
        return reply.code(500).send({ error: 'No se pudo generar el informe' });
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
    // B-04: cuota por usuario. La importación parsea ficheros (y puede llamar al
    // LLM): limitamos a 20/min por usuario para evitar abuso de CPU/coste.
    if (rateLimited(`import:${caller.id}`, 20, 60000)) {
      return reply.code(429).send({ error: 'Demasiadas importaciones, prueba en un minuto' });
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
