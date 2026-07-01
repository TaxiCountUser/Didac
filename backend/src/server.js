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
import { runQuarterlyFleetRewards, quarterOf, quarterRange, computeTenantQuarterMetrics, rewardDaysForRate } from './gamification.js';
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
    await syncSeatQuantity(guard.driver.tenant_id); // baja un asiento de la factura
    return reply.send({ ok: true, id: driverId });
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

  // Defensa en profundidad: TODA ruta /api/v1/admin/* exige admin aquí, aunque
  // el handler también lo verifique. Así un endpoint admin nuevo no puede quedar
  // sin protección por olvido. La memoización evita la doble verificación.
  app.addHook('preHandler', async (request, reply) => {
    const path = (request.url || '').split('?')[0];
    if (!path.startsWith('/api/v1/admin/')) return;
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

    return reply.send({
      tenant,
      users: users || [],
      counts: { vehicles, transactions, incidents },
      summary,                       // null: oculto por protección de datos
      recent_transactions: [],       // oculto por protección de datos
      financials_masked: true,       // el front muestra ***** en vez de cifras
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

    // CIERRE LÓGICO con retención fiscal (5 años): NO borramos la empresa (eso
    // borraría en cascada sus carreras). Marcamos closed_at, anonimizamos y
    // eliminamos las cuentas de acceso; las carreras quedan (user_id -> null) y
    // se purgan a los 5 años (purge_expired_retention).
    const { data: users } = await supabase.from('users').select('id').eq('tenant_id', id);
    const { error } = await supabase.from('tenants').update({
      closed_at: new Date().toISOString(),
      name: 'Empresa dada de baja',
      subscription_status: 'canceled',
      stripe_customer_id: null,
      stripe_subscription_id: null,
      join_code: null,
    }).eq('id', id);
    if (error) return reply.code(400).send({ error: error.message });
    // Elimina las cuentas de auth (sus filas de public.users caen por cascada;
    // las carreras se conservan con user_id null gracias a ON DELETE SET NULL).
    for (const u of users || []) {
      try { await supabase.auth.admin.deleteUser(u.id); } catch (_) {}
    }
    await logAdminAction(request, g.caller.id, 'company_close', 'tenant', id,
      { removed_access: (users || []).length });
    return reply.send({ ok: true, closed: true, removed_access: (users || []).length });
  });

  // Purga de retención: elimina definitivamente las empresas cerradas hace más
  // de 5 años (cascada a sus carreras). Pensado para ejecutarse periódicamente
  // (cron externo o manual). Devuelve cuántas se eliminaron.
  app.post('/api/v1/admin/cron/purge-retention', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { data, error } = await supabase.rpc('purge_expired_retention');
    if (error) return reply.code(500).send({ error: error.message });
    await logAdminAction(request, g.caller.id, 'purge_retention', 'tenant', null, { purged: data ?? 0 });
    return reply.send({ ok: true, purged: data ?? 0 });
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
  const CHALLENGE_MAX_JUMP = 2000;    // salto de km de golpe por encima -> sospechoso
  const CHALLENGE_MAX_INCOME = 1500;  // una carrera por encima de 1500 € -> sospechoso

  // Loop #6: las bases de los retos se leen de system_config:
  //   - money_100k solo se incluye si challenge_100k_euros_enabled = 'true'
  //     (por defecto retirado);
  //   - el reto de días usa challenge_days_required (por defecto 365; ya no hay
  //     "mínimo de 300 días": se logra al llegar al objetivo).
  // La clave interna 'days_300' se mantiene por compatibilidad de datos/UI.
  async function challengeConfig() {
    let euros = false;
    let days = 365;
    try {
      const { data } = await supabase.from('system_config')
        .select('key, value')
        .in('key', ['challenge_100k_euros_enabled', 'challenge_days_required']);
      for (const r of data ?? []) {
        if (r.key === 'challenge_100k_euros_enabled') euros = r.value === 'true';
        if (r.key === 'challenge_days_required') days = parseInt(r.value, 10) || 365;
      }
    } catch { /* sin config -> valores por defecto */ }
    const base = { km_100k: 100000 };
    if (euros) base.money_100k = 100000;
    base.days_300 = days;
    return { base, eurosEnabled: euros, daysRequired: days };
  }

  // Objetivo (incremento) de un reto en un nivel dado. Ciclo de 4 niveles: el
  // 1º de cada ciclo (niveles 1, 5, 9, 13...) vuelve a la base; los otros tres,
  // el doble. Así de vez en cuando "baja" como sorpresa.
  const incrementFor = (base, challenge, level) =>
    (base[challenge] ?? 0) * (((level - 1) % 4) === 0 ? 1 : 2);

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
      const { base } = await challengeConfig();
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
          const target = incrementFor(base, type, st.level);
          const metric = metrics[type];
          const progress = Math.max(0, metric - st.baseline);
          const reached = progress >= target;
          // Loop #4: al alcanzar el tramo se registra el logro YA como 'rewarded'
          // (auto-avance de nivel + cuenta en la métrica trimestral), pero SIN
          // recompensa individual al JEFE (los días gratis los reparte el cron
          // trimestral por % de flota). El admin aún puede rechazarlo por fraude.
          if (reached && !st.pending && !st.rejected) {
            const { error: insErr } = await supabase.from('challenge_claims').insert({
              tenant_id: caller.tenant_id, user_id: r.user_id, challenge: type,
              level: st.level, baseline: st.baseline, target,
              metric_value: metric, active_days: activeDays,
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
      return reply.code(500).send({ error: 'No se pudieron calcular los retos' });
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
        + 'status, created_at, reviewed_at, users:user_id(email, name), tenants:tenant_id(name)')
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
      // Loop #6: se retira el "mínimo de 300 días". El anti-fraude de km real lo
      // da max_jump en la vista de empresa; aquí ya no se marca por días.
      suspicious: false,
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
      .select('user_id, level, status').limit(20000);
    const { count: totalDrivers } = await supabase.from('users')
      .select('id', { count: 'exact', head: true }).eq('role', 'driver');

    let totalCompleted = 0;
    let pendingApprovals = 0;
    const driversWithClaim = new Set();
    const maxLevelByUser = {};        // nivel máximo aprobado por conductor
    for (const c of claims ?? []) {
      driversWithClaim.add(c.user_id);
      if (c.status === 'rewarded') {
        totalCompleted += 1;
        const lvl = c.level ?? 1;
        if (!maxLevelByUser[c.user_id] || lvl > maxLevelByUser[c.user_id]) maxLevelByUser[c.user_id] = lvl;
      } else if (c.status === 'pending') {
        pendingApprovals += 1;
      }
    }
    const levels = Object.values(maxLevelByUser);
    const avgLevel = levels.length ? +(levels.reduce((s, n) => s + n, 0) / levels.length).toFixed(1) : 0;
    const driversWithChallenge = totalDrivers
      ? +((driversWithClaim.size / totalDrivers) * 100).toFixed(1) : 0;

    // Días concedidos: en el modelo nuevo, la recompensa de retos es trimestral.
    const { data: fleetRows } = await supabase.from('fleet_quarterly_metrics')
      .select('reward_days_awarded').limit(20000);
    const daysAwarded = (fleetRows ?? []).reduce((s, r) => s + (r.reward_days_awarded ?? 0), 0);

    return reply.send({
      total_completed: totalCompleted,
      drivers_with_challenge: driversWithChallenge, // %
      avg_level: avgLevel,
      days_awarded: daysAwarded,
      pending_approvals: pendingApprovals,
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
  // Loop #5 — Recompensas trimestrales (vista admin) y ajuste manual.
  // ============================================================

  // Admin: histórico de recompensas trimestrales de todas las empresas.
  // Filtros: ?year= &quarter= &tenant_id=. Paginación ?limit= &offset=.
  app.get('/api/v1/admin/challenges/quarterly', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const qp = request.query ?? {};
    const limit = Math.min(Math.max(parseInt(qp.limit ?? '50', 10) || 50, 1), 200);
    const offset = Math.max(parseInt(qp.offset ?? '0', 10) || 0, 0);
    let q = supabase.from('fleet_quarterly_metrics')
      .select('id, tenant_id, year, quarter, active_drivers, drivers_with_achievement, '
        + 'completion_rate, reward_days_awarded, processed_at, tenant:tenant_id(name)',
        { count: 'exact' })
      .order('year', { ascending: false }).order('quarter', { ascending: false });
    if (qp.year) q = q.eq('year', parseInt(qp.year, 10));
    if (qp.quarter) q = q.eq('quarter', parseInt(qp.quarter, 10));
    if (qp.tenant_id) q = q.eq('tenant_id', qp.tenant_id);
    const { data, count, error } = await q.range(offset, offset + limit - 1);
    if (error) return reply.code(500).send({ error: error.message });
    const rows = (data ?? []).map((r) => ({ ...r, status: r.processed_at ? 'processed' : 'pending' }));
    return reply.send({ metrics: rows, total: count ?? rows.length, limit, offset });
  });

  // Admin: ajustar manualmente una recompensa trimestral. Requiere justificación.
  // Si cambia reward_days_awarded, ajusta la suscripción del tenant por la
  // diferencia (suma o resta días) y queda registrado en auditoría.
  app.put('/api/v1/admin/challenges/quarterly/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const b = request.body ?? {};
    const reason = b.reason;
    if (!reason || !String(reason).trim()) {
      return reply.code(400).send({ error: 'Se requiere una justificación (reason)' });
    }
    if (b.reward_days_awarded == null || isNaN(Number(b.reward_days_awarded))) {
      return reply.code(400).send({ error: 'reward_days_awarded numérico requerido' });
    }
    const newDays = Math.max(0, Math.round(Number(b.reward_days_awarded)));
    const { data: row } = await supabase.from('fleet_quarterly_metrics')
      .select('id, tenant_id, reward_days_awarded').eq('id', request.params.id).maybeSingle();
    if (!row) return reply.code(404).send({ error: 'Métrica trimestral no encontrada' });
    const delta = newDays - (row.reward_days_awarded ?? 0);
    await supabase.from('fleet_quarterly_metrics')
      .update({ reward_days_awarded: newDays }).eq('id', row.id);
    // Ajustar trial_ends_at del tenant por la diferencia (con signo).
    if (delta !== 0) {
      const { data: t } = await supabase.from('tenants')
        .select('trial_ends_at').eq('id', row.tenant_id).maybeSingle();
      const now = Date.now();
      const cur = t?.trial_ends_at ? new Date(t.trial_ends_at).getTime() : now;
      const base = cur > now ? cur : now;
      await supabase.from('tenants')
        .update({ trial_ends_at: new Date(base + delta * 86400000).toISOString() })
        .eq('id', row.tenant_id);
    }
    await logAdminAction(request, g.caller.id, 'quarterly_reward_adjust', 'fleet_quarterly_metrics', row.id,
      { reason: String(reason), previous_days: row.reward_days_awarded ?? 0, new_days: newDays, delta });
    return reply.send({ ok: true, reward_days_awarded: newDays, delta });
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

  // Admin: ejecutar manualmente el reparto trimestral de flota (para probar el
  // cron fuera de horario). body: { year?, quarter?, dryRun? }. Si no se indican
  // year/quarter, usa el trimestre actual. dryRun=true calcula sin premiar.
  app.post('/api/v1/admin/cron/quarterly-rewards', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const b = request.body ?? {};
    try {
      const summary = await runQuarterlyFleetRewards(supabase, {
        year: b.year ? Number(b.year) : undefined,
        quarter: b.quarter ? Number(b.quarter) : undefined,
        dryRun: b.dryRun === true || b.dryRun === 'true',
        notifyOwner: notifyUser,
        log: app.log,
      });
      return reply.send(summary);
    } catch (e) {
      request.log.error(e);
      return reply.code(500).send({ error: 'Fallo en el reparto trimestral' });
    }
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

  // JEFE: histórico de recompensas trimestrales de su empresa (o admin: por
  // tenant_id en query). Paginación opcional ?limit=&offset=.
  app.get('/api/v1/tenant/quarterly-metrics', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (caller.role !== 'owner' && !caller.is_admin) {
      return reply.code(403).send({ error: 'Solo el propietario o el admin' });
    }
    if (rateLimited(`qm:${caller.id}`)) {
      return reply.code(429).send({ error: 'Demasiadas peticiones, prueba en un minuto' });
    }
    // El admin puede consultar otro tenant con ?tenant_id=; el owner, solo el suyo.
    const tenantId = (caller.is_admin && request.query?.tenant_id)
      ? request.query.tenant_id : caller.tenant_id;
    const limit = Math.min(Math.max(parseInt(request.query?.limit ?? '20', 10) || 20, 1), 100);
    const offset = Math.max(parseInt(request.query?.offset ?? '0', 10) || 0, 0);
    const { data, error } = await supabase
      .from('fleet_quarterly_metrics')
      .select('year, quarter, active_drivers, drivers_with_achievement, completion_rate, reward_days_awarded, processed_at')
      .eq('tenant_id', tenantId)
      .order('year', { ascending: false })
      .order('quarter', { ascending: false })
      .range(offset, offset + limit - 1);
    if (error) return reply.code(500).send({ error: error.message });
    return reply.send({ metrics: data ?? [], limit, offset });
  });

  // JEFE: progreso del trimestre EN CURSO, calculado en tiempo real (no espera al
  // cron). Devuelve active_drivers, drivers_with_achievement, completion_rate y la
  // recompensa proyectada si el trimestre cerrara ahora.
  app.get('/api/v1/tenant/current-quarter-progress', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (caller.role !== 'owner' && !caller.is_admin) {
      return reply.code(403).send({ error: 'Solo el propietario o el admin' });
    }
    if (rateLimited(`cqp:${caller.id}`)) {
      return reply.code(429).send({ error: 'Demasiadas peticiones, prueba en un minuto' });
    }
    const tenantId = (caller.is_admin && request.query?.tenant_id)
      ? request.query.tenant_id : caller.tenant_id;
    try {
      const { year, quarter } = quarterOf();
      const range = quarterRange(year, quarter);
      const since30ISO = new Date(Date.now() - 30 * 86400000).toISOString();
      const m = await computeTenantQuarterMetrics(supabase, tenantId, range, since30ISO);
      return reply.send({
        year, quarter,
        ...m,
        reward_days_projected: rewardDaysForRate(m.completion_rate),
      });
    } catch (e) {
      request.log.error(e);
      return reply.code(500).send({ error: 'No se pudo calcular el progreso' });
    }
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
        validation_days: parseInt(cfg.referral_validation_days ?? '30', 10),
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

  // Configuración de hitos y parámetros (lectura). Devuelve claves referral_*
  // y los hitos ya parseados.
  app.get('/api/v1/admin/referrals/config', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const cfg = await refConfig();
    const referral = Object.fromEntries(Object.entries(cfg).filter(([k]) => k.startsWith('referral_')));
    return reply.send({ config: referral, milestones: milestonesFrom(cfg) });
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
    // Cancelación dentro de la gracia -> 'rejected' (según spec); reverted_at deja
    // constancia de que fue por cancelación. recompute revoca el hito (clawback).
    await supabase.from('referrals')
      .update({ status: 'rejected', reverted_at: new Date().toISOString() }).eq('id', ref.id);
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

  // Loop #6: se RETIRA el reparto trimestral por % de flota (Loop #4). La nueva
  // recompensa es POR CONDUCTOR: cada reto completado (challenge_claims.status =
  // 'rewarded') otorga 1 mes-asiento gratis al jefe, que se aplica en la
  // facturación por asiento (Stripe, Iteración 7). El scheduler queda desactivado
  // para no seguir concediendo días por flota. Los endpoints e histórico
  // trimestral se conservan solo como consulta (datos ya generados).
  //
  // if (supabase && process.env.NODE_ENV !== 'test') {
  //   scheduleQuarterly(supabase, { notifyOwner: notifyUser, log: app.log });
  //   app.log.info('[cron] Scheduler trimestral de flota activado.');
  // }

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
