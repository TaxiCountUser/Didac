import 'dotenv/config';
import { pathToFileURL } from 'node:url';
import { randomBytes, createHash, timingSafeEqual } from 'node:crypto';
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
import { handleStripeEvent, planForPrice } from './billing.js';
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
// Price ID anual (para saber si el checkout admite cupones: solo el anual).
const STRIPE_PRICE_SEAT_YEARLY = process.env.STRIPE_PRICE_SEAT_YEARLY || '';
// Tope del modelo por asiento: más conductores = plan a medida (contacto).
const MAX_SEATS = Number(process.env.MAX_SEATS || 100);
// Eventos de Stripe que cambian el cupo de asientos -> reaplicar enforceSeatLimit.
const SEAT_EVENTS = new Set([
  'checkout.session.completed',
  'customer.subscription.created',
  'customer.subscription.updated',
  'invoice.paid',
]);
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
  const { data: res, response } = await client.audio.transcriptions.create({
    file,
    model: WHISPER_MODEL,
    prompt,
    ...(language ? { language } : {}),
  }).withResponse();
  // _headers: cabeceras de rate-limit (x-ratelimit-*) para el monitor de uso de Groq.
  return { text: res.text, confidence: 0.95, _headers: response?.headers, _model: WHISPER_MODEL };
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

async function parseSmart(text, { language, log, markService, markGroqRateLimit } = {}) {
  const deterministic = parseTransactionText(text);
  if (!LLM_PARSE_MODEL || !OPENAI_API_KEY) return zeroIfNoAmount(deterministic);
  try {
    const llm = await withTimeout(
      llmParse(text, {
        apiKey: OPENAI_API_KEY,
        baseURL: OPENAI_BASE_URL,
        model: LLM_PARSE_MODEL,
        language,
        onRateLimit: markGroqRateLimit,
      }),
      LLM_PARSE_TIMEOUT_MS,
    );
    markService?.('openai', true);
    return zeroIfNoAmount(mergeParsed(llm, deterministic));
  } catch (e) {
    markService?.('openai', false);
    log?.warn?.(`LLM parse falló (${e.message}); uso parser determinista`);
    return zeroIfNoAmount(deterministic);
  }
}

/**
 * @param {object} [options]
 * @param {(input:{buffer?:Buffer,filename?:string,mockText?:string})=>Promise<{text:string,confidence:number}>} [options.transcribe]
 *        Permite inyectar un transcriptor (mock) en tests.
 */
// Logger (T5): en tests, silencio. Si hay LOGTAIL_SOURCE_TOKEN (Better Stack),
// los logs van a stdout (consola de Render, como siempre) Y a Better Stack
// (retención + búsqueda). Sin token, stdout y ya está. Nota: los Log Streams
// nativos de Render exigen workspace Professional; este transporte de pino
// hace lo mismo gratis desde la app.
function loggerConfig() {
  if (process.env.NODE_ENV === 'test') return false;
  const token = (process.env.LOGTAIL_SOURCE_TOKEN || '').trim();
  if (!token) return true;
  const host = (process.env.LOGTAIL_INGESTING_HOST || 'in.logs.betterstack.com').trim();
  return {
    transport: {
      targets: [
        { target: 'pino/file', options: { destination: 1 } }, // stdout (Render)
        {
          target: '@logtail/pino',
          options: { sourceToken: token, options: { endpoint: `https://${host}` } },
        },
      ],
    },
  };
}

export async function buildApp(options = {}) {
  // trustProxy: detrás del proxy de Render, request.ip debe ser la IP REAL del
  // cliente (no la del proxy), o los límites por IP (rate-limit, anti-fuerza
  // bruta del login) no distinguen a nadie. Por defecto 1 salto (el proxy de
  // Render); configurable con TRUST_PROXY_HOPS. Contar saltos (no `true`) evita
  // que un cliente falsee X-Forwarded-For.
  const trustProxy = process.env.TRUST_PROXY_HOPS !== undefined
    ? Number(process.env.TRUST_PROXY_HOPS)
    : 1;
  const app = Fastify({ logger: loggerConfig(), trustProxy });

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

  // CORS: en producción NO reflejar cualquier origen. Si CORS_ORIGIN no está
  // definido, se cae a un origen conocido (la web oficial) en vez de `true`
  // (fail-closed). En desarrollo sí se permite todo para comodidad.
  let corsOrigin;
  if (process.env.CORS_ORIGIN) {
    corsOrigin = process.env.CORS_ORIGIN.split(',').map((s) => s.trim()).filter(Boolean);
  } else if (process.env.NODE_ENV === 'production') {
    corsOrigin = ['https://taxicountuser.github.io'];
    app.log.warn('[cors] CORS_ORIGIN no definido: se usa el origen por defecto '
      + `(${corsOrigin.join(', ')}). Define CORS_ORIGIN si tu web está en otra URL.`);
  } else {
    corsOrigin = true; // dev
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
      // console además del logger: en tests el logger está desactivado y este
      // fallo quedaba invisible (app.supabase null sin explicación).
      console.error(`[supabase] createClient falló: ${e.message}`);
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

  // Comprueba y actualiza el límite diario en UNA operación atómica (evita el
  // TOCTOU de leer/comprobar/escribir por separado). Devuelve true si se permite.
  async function bumpDailyLimit(caller) {
    const { data, error } = await supabase.rpc('bump_daily_transcription', {
      p_user: caller.id, p_limit: DAILY_LIMIT,
    });
    if (error) {
      app.log.warn(`[transcribe] bump_daily_transcription: ${error.message}`);
      return false; // fail-closed: si no se puede contabilizar, no se permite
    }
    return data === true;
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
    // Commit desplegado (Render expone RENDER_GIT_COMMIT): permite comprobar
    // desde fuera si un push ya está en producción o aún se está desplegando.
    commit: (process.env.RENDER_GIT_COMMIT || '').slice(0, 7) || undefined,
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
      const parsed = await parseSmart(cached.text, { language, log: request.log, markService, markGroqRateLimit });
      return reply.send({ ...cached, parsed, cached: true });
    }

    // Límite diario (solo cuando vamos a llamar de verdad a Whisper)
    const allowed = await bumpDailyLimit(caller);
    if (!allowed) {
      return reply.code(429).send({ error: 'Límite diario de transcripciones alcanzado' });
    }

    // Transcribir (mock o real) con timeout + un reintento
    const realWhisper = !(ALLOW_MOCK && mockText); // los mocks no cuentan para el semáforo
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
      if (realWhisper) {
        markService('whisper', true);
        if (result?._headers) markGroqRateLimit(result._headers, result._model);
      }
    } catch (e) {
      if (realWhisper) markService('whisper', false);
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
    delete result._headers; delete result._model; // internos: no van en la respuesta
    transcriptionCache.set(cacheKey, result);
    const parsed = await parseSmart(result.text, { language, log: request.log, markService, markGroqRateLimit });
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
      const parsed = await parseSmart(corrected, { language, log: request.log, markService, markGroqRateLimit });
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

    // Solo cuentan los conductores ACTIVOS (los que ocupan asiento). Los dados
    // de baja no cuentan para ningún límite.
    const { count: activeCount } = await supabase
      .from('users')
      .select('id', { count: 'exact', head: true })
      .eq('tenant_id', caller.tenant_id)
      .eq('role', 'driver')
      .eq('active', true);

    // Tope máximo absoluto por app: MAX_DRIVERS. Por encima, plan a medida.
    if ((activeCount ?? 0) >= MAX_DRIVERS) {
      return reply.code(403).send({
        error: `Has alcanzado el máximo de ${MAX_DRIVERS} conductores. Contacta con nosotros para ampliar tu flota.`,
      });
    }

    // Límite por ASIENTOS PAGADOS: en modo de pago (suscripción activa) solo se
    // pueden tener tantos conductores ACTIVOS como asientos se pagan
    // (tenants.drivers_limit = cantidad de la suscripción de Stripe). Durante la
    // PRUEBA no hay límite (hasta MAX_DRIVERS). Para añadir por encima de lo
    // pagado, primero hay que comprar un asiento (POST /api/v1/subscription/seats).
    const { data: tenant } = await supabase
      .from('tenants')
      .select('drivers_limit, subscription_status')
      .eq('id', caller.tenant_id)
      .single();
    const paid = tenant?.subscription_status === 'active' || tenant?.subscription_status === 'past_due';
    const seats = tenant?.drivers_limit;
    if (paid && seats != null && (activeCount ?? 0) >= seats) {
      return reply.code(403).send({
        code: 'seat_limit', seats,
        error: `Pagas ${seats} asiento(s) y ya están ocupados. Compra un asiento más para añadir este conductor.`,
      });
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
    // NO se ajusta la factura al añadir: en el modelo de asientos pre-pagados el
    // jefe ya paga por su cupo (drivers_limit); ocupar un asiento libre no cobra.
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
    const activating = active === true || active === 'true';
    if (active !== undefined) patch.active = activating;

    // Reactivar ocupa un asiento: en modo de pago no se puede pasar del cupo
    // pagado (drivers_limit). Para más, comprar asientos (/subscription/seats).
    if (activating) {
      const { data: t } = await supabase.from('tenants')
        .select('drivers_limit, subscription_status').eq('id', guard.driver.tenant_id).maybeSingle();
      const paid = t?.subscription_status === 'active' || t?.subscription_status === 'past_due';
      if (paid && t?.drivers_limit != null) {
        const { count: activeCount } = await supabase.from('users')
          .select('id', { count: 'exact', head: true })
          .eq('tenant_id', guard.driver.tenant_id).eq('role', 'driver').eq('active', true);
        if ((activeCount ?? 0) >= t.drivers_limit) {
          return reply.code(403).send({
            code: 'seat_limit', seats: t.drivers_limit,
            error: `Pagas ${t.drivers_limit} asiento(s) y ya están ocupados. Compra un asiento más para reactivar este conductor.`,
          });
        }
      }
    }

    if (Object.keys(patch).length > 0) {
      const { error: uErr } = await supabase.from('users').update(patch).eq('id', driverId);
      if (uErr) {
        const dup = /duplicate|unique|23505/i.test(uErr.message || '');
        return reply
          .code(dup ? 409 : 400)
          .send({ error: dup ? 'Ese nombre de usuario ya está en uso' : uErr.message });
      }
    }
    // Dar de baja libera el asiento para reutilizarlo; NO cambia lo que se paga.
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
    // Libera el asiento para reutilizarlo; NO cambia lo que se paga (asientos
    // pre-pagados). Para pagar menos, el jefe reduce asientos en su suscripción.
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

  // Registra el resultado (ok/err) de la última llamada a un servicio externo
  // —whisper (transcripción) u openai (parser LLM)— para los semáforos del panel
  // de admin. Guarda "ok|<iso>" o "err|<iso>". Best-effort y sin await en el hot
  // path (fire-and-forget): nunca ralentiza ni rompe la transcripción.
  function markService(name, ok) {
    supabase.from('system_config').upsert(
      { key: `svc_${name}`, value: `${ok ? 'ok' : 'err'}|${new Date().toISOString()}` },
      { onConflict: 'key' },
    ).then(({ error }) => {
      if (error) app.log.warn(`[svc] no se pudo registrar svc_${name}: ${error.message}`);
    }, (e) => app.log.warn(`[svc] svc_${name}: ${e.message}`));
  }

  // Guarda la última "foto" de rate-limit de Groq/OpenAI a partir de las cabeceras
  // de la respuesta (x-ratelimit-*). Permite el monitor de uso en el panel: el %
  // restante en vivo del recurso más ajustado (peticiones o tokens). Best-effort.
  function markGroqRateLimit(headers, model) {
    if (!headers || !model) return;
    const get = (k) => {
      try { return headers.get ? headers.get(k) : headers[k]; } catch { return null; }
    };
    const num = (k) => { const v = Number(get(k)); return Number.isFinite(v) ? v : null; };
    // Nota: Groq limita TAMBIÉN la transcripción (Whisper) por PETICIONES (no por
    // segundos de audio: no envía esa cabecera). Así que Whisper aparece por su
    // propio contador de peticiones, igual que el modelo de chat.
    const snap = {
      model,
      rem_req: num('x-ratelimit-remaining-requests'),
      lim_req: num('x-ratelimit-limit-requests'),
      rem_tok: num('x-ratelimit-remaining-tokens'),
      lim_tok: num('x-ratelimit-limit-tokens'),
      at: new Date().toISOString(),
    };
    if (snap.rem_req == null && snap.rem_tok == null) return; // no vienen cabeceras
    // Una foto POR MODELO: el parser (llama) y Whisper (transcripción) tienen su
    // propio rate-limit, así que se guardan en claves separadas (svc_groq_rl:<modelo>)
    // para que NO se pisen entre sí y ambos aparezcan en el panel.
    supabase.from('system_config').upsert(
      { key: `svc_groq_rl:${model}`, value: JSON.stringify(snap) }, { onConflict: 'key' },
    ).then(({ error }) => {
      if (error) app.log.warn(`[groq-rl] ${error.message}`);
    }, (e) => app.log.warn(`[groq-rl] ${e.message}`));
  }

  // ── Monitor de uso: Groq (rate-limit en vivo) + recursos de Supabase ───────
  // Uso de Groq: % RESTANTE del recurso más ajustado (peticiones o tokens) según
  // la última foto de cabeceras (svc_groq_rl). <20% restante => alerta.
  // % restante por modelo (el recurso más ajustado: peticiones o tokens).
  function groqModelPct(s) {
    const pcts = [];
    if (s.lim_req > 0 && s.rem_req != null) pcts.push(s.rem_req / s.lim_req);
    if (s.lim_tok > 0 && s.rem_tok != null) pcts.push(s.rem_tok / s.lim_tok);
    return pcts.length ? Math.round(Math.min(...pcts) * 100) : null;
  }

  async function groqUsage() {
    try {
      const { data } = await supabase.from('system_config')
        .select('key, value').like('key', 'svc_groq_rl%');
      // Dedup por modelo (quedándonos con la foto más reciente); incluye la clave
      // antigua 'svc_groq_rl' (foto única) por compatibilidad.
      const byModel = {};
      for (const r of data ?? []) {
        let s; try { s = JSON.parse(r.value); } catch { continue; }
        const model = s.model || r.key.replace('svc_groq_rl:', '') || '?';
        if (!byModel[model] || new Date(s.at) > new Date(byModel[model].at)) byModel[model] = s;
      }
      const models = Object.entries(byModel).map(([model, s]) => ({
        model, at: s.at, remaining_pct: groqModelPct(s),
        requests: { remaining: s.rem_req, limit: s.lim_req },
        tokens: { remaining: s.rem_tok, limit: s.lim_tok },
      })).filter((m) => m.remaining_pct != null)
        .sort((a, b) => a.remaining_pct - b.remaining_pct);
      if (!models.length) return { available: false };
      // remaining_pct global = el modelo más ajustado (para el resumen/semáforo).
      return { available: true, remaining_pct: models[0].remaining_pct, models };
    } catch { return { available: false }; }
  }

  // Extrae RAM%, disco% y los contadores de CPU de un texto Prometheus
  // (node_exporter de Supabase). El %CPU se calcula fuera, por delta entre dos
  // fotos (ver supabaseMetrics), no aquí: una sola foto no da uso de CPU.
  function parsePromMetrics(text) {
    const lines = text.split('\n');
    const sumMetric = (prefix, labelFilter) => {
      let total = 0, found = false;
      for (const ln of lines) {
        if (ln.startsWith('#') || !ln.startsWith(prefix)) continue;
        if (labelFilter && !labelFilter(ln)) continue;
        const v = Number(ln.slice(ln.lastIndexOf(' ') + 1));
        if (Number.isFinite(v)) { total += v; found = true; }
      }
      return found ? total : null;
    };
    // RAM
    const memTotal = sumMetric('node_memory_MemTotal_bytes');
    const memAvail = sumMetric('node_memory_MemAvailable_bytes');
    const ram_pct = (memTotal && memAvail != null)
      ? Math.round((1 - memAvail / memTotal) * 100) : null;
    // Disco: filesystem de mayor tamaño (el volumen de datos).
    const fs = {};
    for (const ln of lines) {
      const m = ln.match(/^node_filesystem_(size|avail)_bytes\{([^}]*)\}\s+([\d.eE+-]+)/);
      if (!m) continue;
      const mp = (m[2].match(/mountpoint="([^"]*)"/) || [])[1] || '?';
      (fs[mp] ??= {})[m[1]] = Number(m[3]);
    }
    let disk_pct = null, biggest = 0, disk_total = null, disk_avail = null;
    for (const mp of Object.keys(fs)) {
      const f = fs[mp];
      if (f.size > 0 && f.avail != null && f.size > biggest) {
        biggest = f.size; disk_pct = Math.round((1 - f.avail / f.size) * 100);
        disk_total = f.size; disk_avail = f.avail;
      }
    }
    // CPU: contadores acumulados (segundos). El % se saca por delta entre fotos.
    const cpu_idle = sumMetric('node_cpu_seconds_total', (ln) => ln.includes('mode="idle"'));
    const cpu_total = sumMetric('node_cpu_seconds_total');
    // Carga del sistema (gauges puntuales, sin delta) y memoria total/libre.
    const load1 = sumMetric('node_load1');
    const load5 = sumMetric('node_load5');
    const load15 = sumMetric('node_load15');
    return {
      available: true, ram_pct, disk_pct, cpu_idle, cpu_total,
      disk_total, disk_avail, mem_total: memTotal, mem_avail: memAvail,
      load1, load5, load15,
    };
  }

  // %CPU a partir de dos fotos de contadores (idle/total en segundos).
  function cpuPctFromCounters(base, cur) {
    if (!base || cur.cpu_total == null || base.cpu_total == null) return null;
    const dIdle = cur.cpu_idle - base.cpu_idle;
    const dTot = cur.cpu_total - base.cpu_total;
    if (!(dTot > 0)) return null;
    return Math.max(0, Math.min(100, Math.round((1 - dIdle / dTot) * 100)));
  }

  // Métricas de Supabase: RPC de BD (tamaño/conexiones, siempre) + scrape del
  // endpoint privilegiado de métricas del proyecto (CPU/RAM/disco, best-effort).
  // Guarda una foto del sistema en svc_supabase_res para los semáforos (sin
  // rehacer el scrape en cada chequeo).
  async function supabaseMetrics() {
    const out = { db: null, system: null, at: new Date().toISOString() };
    try {
      const { data } = await supabase.rpc('db_resource_stats');
      if (data) out.db = data;
    } catch (e) { app.log.warn(`[metrics] db_resource_stats: ${e.message}`); }
    const auth = Buffer.from(`service_role:${SUPABASE_SERVICE_ROLE_KEY}`).toString('base64');
    const scrape = async () => {
      const r = await fetch(`${SUPABASE_URL}/customer/v1/privileged/metrics`, {
        headers: { Authorization: `Basic ${auth}` },
        signal: AbortSignal.timeout(6000),
      });
      return r.ok ? parsePromMetrics(await r.text()) : { available: false, status: r.status };
    };
    // Foto anterior de contadores de CPU (persistida) para el delta.
    let prev = null;
    try {
      const { data } = await supabase.from('system_config')
        .select('value').eq('key', 'svc_supabase_res').maybeSingle();
      if (data?.value) prev = JSON.parse(data.value);
    } catch { /* sin foto previa */ }
    try {
      let sys = await scrape();
      if (sys.available) {
        // %CPU vs la foto anterior; si no sirve (primer arranque o contador
        // reiniciado), toma una 2ª muestra ~1,2 s después para un delta inmediato.
        let cpu = cpuPctFromCounters(prev, sys);
        if (cpu == null) {
          const base = sys;
          await new Promise((res) => setTimeout(res, 1200));
          const sys2 = await scrape();
          if (sys2.available) { cpu = cpuPctFromCounters(base, sys2); sys = sys2; }
        }
        sys.cpu_pct = cpu;
      }
      out.system = sys;
    } catch (e) {
      out.system = { available: false, error: e.message };
    }
    // Guarda la foto del sistema (best-effort) para los semáforos y el próximo delta.
    if (out.system?.available) {
      supabase.from('system_config').upsert(
        { key: 'svc_supabase_res', value: JSON.stringify({ ...out.system, at: out.at }) },
        { onConflict: 'key' },
      ).then(() => {}, () => {});
    }
    return out;
  }

  // ── Feature flags (Mes 2, M2-7) ───────────────────────────────────────────
  // Interruptores de plataforma en `system_config` con prefijo `flag_`. Permiten
  // conmutar comportamiento SIN redeploy (p. ej. el procesamiento asíncrono del
  // webhook) y volver atrás al instante. Se cachean unos segundos para no golpear
  // la BD en cada webhook; el POST /admin/flags invalida la caché al escribir.
  const FLAG_CACHE_MS = process.env.WEBHOOK_FLAG_TTL_MS !== undefined
    ? Number(process.env.WEBHOOK_FLAG_TTL_MS) : 15000;
  let _flagCache = { at: 0, val: {} };
  async function loadFlags() {
    if (Date.now() - _flagCache.at < FLAG_CACHE_MS) return _flagCache.val;
    const val = {};
    try {
      const { data } = await supabase.from('system_config')
        .select('key, value').like('key', 'flag_%');
      for (const r of data ?? []) val[r.key.replace('flag_', '')] = r.value;
    } catch { /* best-effort: sin flags => valores por defecto */ }
    _flagCache = { at: Date.now(), val };
    return val;
  }
  async function flagOn(name, def = false) {
    const v = (await loadFlags())[name];
    if (v === undefined || v === null || v === '') return def;
    return v === 'on' || v === 'true' || v === '1';
  }
  function invalidateFlagCache() { _flagCache = { at: 0, val: {} }; }

  // Sonda de salud de la BD (Supabase): mide una lectura trivial. Observa la
  // degradación (lenta) aunque acabe respondiendo. ok si <800ms, slow si más,
  // error si falla. Se usa en /overview y /semaphores para el semáforo "BD".
  async function probeDb() {
    const t0 = Date.now();
    try {
      const { error } = await supabase.from('system_config').select('key').limit(1);
      const ms = Date.now() - t0;
      if (error) return { ok: false, status: 'error', latency_ms: ms, at: new Date().toISOString() };
      return { ok: true, status: ms < 800 ? 'ok' : 'slow', latency_ms: ms, at: new Date().toISOString() };
    } catch (e) {
      return { ok: false, status: 'error', latency_ms: Date.now() - t0, at: new Date().toISOString() };
    }
  }

  // ¿Viene de un scheduler externo con el secreto de cron correcto? Comparación
  // en tiempo CONSTANTE (evita timing attacks sobre el secreto).
  function cronAuthorized(request) {
    if (!CRON_SECRET) return false;
    const provided = request.headers['x-cron-secret'];
    if (typeof provided !== 'string' || provided.length === 0) return false;
    const a = Buffer.from(provided);
    const b = Buffer.from(CRON_SECRET);
    return a.length === b.length && timingSafeEqual(a, b);
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
  // Registrar el token FCM del dispositivo del usuario actual. Va por el backend
  // (service_role) a propósito: el token es ÚNICO por dispositivo y, al cambiar
  // de usuario en el MISMO móvil (jefe/admin/conductor de prueba), hay que
  // REASIGNARLO a quien inicia sesión ahora. Con el upsert directo desde el
  // cliente, reasignar un token que pertenece a otro usuario lo bloquea el RLS
  // (la fila existente no cumple USING user_id=auth.uid()) y fallaba en silencio:
  // el token se quedaba con el primer usuario y los demás no recibían nada.
  app.post('/api/v1/device-token', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    const b = request.body ?? {};
    const token = String(b.token ?? '').trim();
    if (!token) return reply.code(400).send({ error: 'Falta el token' });
    const platform = b.platform ? String(b.platform).slice(0, 40) : null;
    // El tenant SIEMPRE es el del llamante (no se acepta del body: evitar que se
    // marque el token con un tenant ajeno).
    const tenantId = caller.tenant_id ?? null;
    const { error } = await supabase.from('device_tokens').upsert({
      user_id: caller.id,
      tenant_id: tenantId,
      token,
      platform,
      updated_at: new Date().toISOString(),
    }, { onConflict: 'token' });
    if (error) return reply.code(400).send({ error: error.message });
    return reply.send({ ok: true });
  });

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

  // ---- Ingresos REALES cobrados (fuente de verdad = Stripe). Suma las facturas
  // pagadas: `paid` = neto cobrado (lo que han pagado los clientes), `discount` =
  // total descontado con cupones. En céntimos. El global se cachea 60 s para no
  // listar Stripe en cada carga del panel.
  function dayBounds() {
    const t = new Date(); t.setUTCHours(0, 0, 0, 0);
    const startTodayS = Math.floor(t.getTime() / 1000);
    const d = new Date();
    const startMonthS = Math.floor(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), 1) / 1000);
    return { startTodayS, startMonthS };
  }

  async function sumPaidInvoices(params) {
    let paid = 0;
    let discount = 0;
    let count = 0;
    let currency = 'eur';
    let paidToday = 0;
    let countToday = 0;
    let paidMtd = 0;
    const byCustomer = {}; // customerId -> total pagado (céntimos), para el módulo de facturación
    const { startTodayS, startMonthS } = dayBounds();
    for await (const inv of stripe.invoices.list({ status: 'paid', limit: 100, ...params })) {
      const amt = inv.amount_paid || 0;
      paid += amt;
      for (const d of inv.total_discount_amounts || []) discount += d.amount || 0;
      count += 1;
      if (inv.currency) currency = inv.currency;
      const cust = typeof inv.customer === 'string' ? inv.customer : inv.customer?.id;
      if (cust) byCustomer[cust] = (byCustomer[cust] || 0) + amt;
      const at = inv.status_transitions?.paid_at ?? inv.created ?? 0;
      if (at >= startTodayS) { paidToday += amt; countToday += 1; }
      if (at >= startMonthS) paidMtd += amt;
    }
    return { paid, discount, count, currency, paidToday, countToday, paidMtd, byCustomer };
  }

  // Total DEVUELTO (reembolsos). Las facturas pagadas no cambian al reembolsar,
  // así que se mira aparte: global vía refunds.list; por cliente vía sus charges
  // (refunds no se puede filtrar por customer).
  async function sumRefunds(customerId) {
    let refunded = 0;
    let refundedToday = 0;
    const { startTodayS } = dayBounds();
    if (customerId) {
      for await (const ch of stripe.charges.list({ customer: customerId, limit: 100 })) {
        refunded += ch.amount_refunded || 0;
      }
    } else {
      for await (const r of stripe.refunds.list({ limit: 100 })) {
        if (r.status === 'failed' || r.status === 'canceled') continue;
        refunded += r.amount || 0;
        if ((r.created ?? 0) >= startTodayS) refundedToday += r.amount || 0;
      }
    }
    return { refunded, refundedToday };
  }

  let _revenueCache = null; // { at, data }
  async function readGlobalRevenue() {
    if (!stripe) return null;
    if (_revenueCache && Date.now() - _revenueCache.at < 60000) return _revenueCache.data;
    try {
      const data = await sumPaidInvoices({});
      const ref = await sumRefunds(null);
      data.refunded = ref.refunded;
      data.refundedToday = ref.refundedToday;
      _revenueCache = { at: Date.now(), data };
      return data;
    } catch (e) {
      app.log.warn(`[revenue] global: ${e.message}`);
      return _revenueCache?.data ?? null;
    }
  }

  async function readTenantRevenue(customerId) {
    if (!stripe || !customerId) return { paid: 0, discount: 0, count: 0, refunded: 0, currency: 'eur' };
    try {
      const data = await sumPaidInvoices({ customer: customerId });
      data.refunded = (await sumRefunds(customerId)).refunded;
      return data;
    } catch (e) {
      app.log.warn(`[revenue] tenant: ${e.message}`);
      return { paid: 0, discount: 0, count: 0, refunded: 0, currency: 'eur' };
    }
  }

  // MRR REAL (Monthly Recurring Revenue): NO es una proyección, es la foto AHORA
  // del ingreso recurrente. Se lee de las subscripciones vivas de Stripe (active +
  // past_due: siguen suscritas aunque falle el cobro) sumando, por item,
  // unit_amount×cantidad normalizado a mes (anual /12). MRR bruto (antes de
  // cupones). unit_amount puede venir null -> fallbacks como en el ajuste de
  // asientos. ARR = MRR×12. Caché 60 s.
  let _mrrCache = null;
  async function readMrr() {
    if (!stripe) return null;
    if (_mrrCache && Date.now() - _mrrCache.at < 60000) return _mrrCache.data;
    try {
      let mrr = 0; // céntimos/mes
      let subs = 0;
      for (const status of ['active', 'past_due']) {
        for await (const s of stripe.subscriptions.list(
            { status, limit: 100, expand: ['data.items.data.price'] })) {
          subs += 1;
          for (const it of s.items?.data ?? []) {
            const p = it.price || {};
            let unit = p.unit_amount;
            if (unit == null && p.unit_amount_decimal != null) unit = Math.round(Number(p.unit_amount_decimal));
            const interval = p.recurring?.interval || 'month';
            if (unit == null || Number.isNaN(unit)) unit = interval === 'year' ? 3000 : 250;
            const qty = it.quantity ?? 1;
            mrr += interval === 'year' ? (unit * qty) / 12 : unit * qty;
          }
        }
      }
      const data = { mrr: Math.round(mrr), subs };
      _mrrCache = { at: Date.now(), data };
      return data;
    } catch (e) {
      app.log.warn(`[mrr] ${e.message}`);
      return _mrrCache?.data ?? null;
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
        subtitle: `referidos · ${a.severity ?? ''}`.trim(), created_at: a.created_at, module: 'referrals' });
    }
    for (const a of genAlerts ?? []) {
      inbox.push({ type: 'fraud', id: a.id, title: a.description || a.alert_type || 'Alerta de fraude',
        subtitle: a.severity ?? '', tenant_id: a.tenant_id, created_at: a.created_at, module: 'referrals' });
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
    const prio = { fraud: 0, challenge: 1, ticket: 2, trial: 3 };
    inbox.sort((a, b) => (prio[a.type] - prio[b.type])
      || (new Date(a.created_at).getTime() - new Date(b.created_at).getTime()));

    // Última ejecución de cada cron (markCronRun) para los semáforos.
    const { data: cronRows } = await supabase.from('system_config')
      .select('key, value').like('key', 'cron_last_%');
    const crons = {};
    for (const r of cronRows ?? []) crons[r.key.replace('cron_last_', '')] = r.value;

    // Estado de los servicios externos (whisper/openai) para sus semáforos.
    // Valor guardado: "ok|<iso>" o "err|<iso>". ok=false solo si el último
    // intento falló (así la inactividad no da falsos rojos).
    const { data: svcRows } = await supabase.from('system_config')
      .select('key, value').like('key', 'svc_%');
    const services = {};
    for (const r of svcRows ?? []) {
      const [status, at] = String(r.value || '').split('|');
      // Error antiguo (>24 h) deja de alertar (mismo criterio que los semáforos).
      const recentErr = status === 'err' && at
        && (now - new Date(at).getTime() < 24 * 60 * 60 * 1000);
      services[r.key.replace('svc_', '')] = { ok: !recentErr, at: at || null };
    }
    // Push sin configurar = apagado a propósito, no avería (ignora errores viejos).
    if (!pushEnabled()) services.push = { ok: true, at: null, off: true };
    const cronStale = ['challenge_credits', 'referral_validations'].some((k) => {
      const v = crons[k];
      return !v || now - new Date(v).getTime() > 2 * dayMs;
    });

    // Eventos de Stripe sin aplicar (bandeja webhook_events): 0 = sano. Cuenta los
    // rotos ('error'/'dead') y los atascados ('received' > 10 min = backlog async).
    // Best-effort (la tabla puede no existir aún en prod → se trata como 0).
    let webhookErrors = 0;
    try {
      const stuckCutoff = new Date(now - 10 * 60 * 1000).toISOString();
      const [brokenRes, stuckRes] = await Promise.all([
        supabase.from('webhook_events').select('event_id', { count: 'exact', head: true })
          .in('status', ['error', 'dead']),
        supabase.from('webhook_events').select('event_id', { count: 'exact', head: true })
          .eq('status', 'received').lt('received_at', stuckCutoff),
      ]);
      webhookErrors = (brokenRes.count ?? 0) + (stuckRes.count ?? 0);
    } catch { /* tabla webhook_events aún no desplegada */ }

    // Salud 0-100: penaliza fraude abierto, tickets envejecidos, impagos,
    // crons parados y errores nuevos. Transparente y estable.
    let health = 100;
    health -= Math.min(30, fraudOpen * 15);
    health -= Math.min(15, ticketsOld * 5);
    health -= pastDue.length > 0 ? 10 : 0;
    health -= cronStale ? 10 : 0;
    health -= webhookErrors > 0 ? 10 : 0; // cobros/cancelaciones sin reflejar
    health = Math.max(0, Math.round(health));

    // Ingresos reales cobrados (Stripe): total facturado neto + lo descontado con
    // cupones. En euros. Best-effort: si Stripe no responde, revenue = null.
    const revenue = await readGlobalRevenue();

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
      revenue: revenue ? {
        // Neto REAL en caja: facturado pagado menos lo devuelto (reembolsos).
        paid_total: Number(((revenue.paid - (revenue.refunded || 0)) / 100).toFixed(2)),
        coupon_total: Number((revenue.discount / 100).toFixed(2)),
        refund_total: Number(((revenue.refunded || 0) / 100).toFixed(2)),
        invoices: revenue.count,
        currency: revenue.currency,
      } : null,
      pending: {
        fraud: fraudOpen,
        challenges: suspicious?.length ?? 0,
        tickets: tickets?.length ?? 0,
        trials_ending: trialSoon.length,
      },
      inbox: inbox.slice(0, 12),
      crons,
      services,
      webhook_errors: webhookErrors,
      database: await probeDb(),
      health,
    });
  });

  // ---- Pols diari: métricas agregadas de la plataforma. PROTECCIÓN DE DATOS: el
  // admin NO ve el dinero de las carreras de los clientes; aquí solo hay NÚMEROS
  // (recuentos) y, en €, únicamente NUESTROS ingresos (suscripciones de Stripe).
  app.get('/api/v1/admin/daily-metrics', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });

    const startToday = new Date(); startToday.setUTCHours(0, 0, 0, 0);
    const todayIso = startToday.toISOString();
    const todayDate = todayIso.slice(0, 10);
    const weekAgoIso = new Date(Date.now() - 7 * 86400000).toISOString();
    const now = Date.now();
    const dayMs = 86400000;

    const countSince = async (table, col, sinceIso, extra) => {
      let q = supabase.from(table).select('id', { count: 'exact', head: true }).gte(col, sinceIso);
      if (extra) q = extra(q);
      const { count } = await q;
      return count || 0;
    };

    // --- Uso (recuentos, sin importes) ---
    const ridesToday = await countSince('transactions', 'created_at', todayIso, (q) => q.eq('type', 'income'));
    // DAU: usuarios distintos con actividad hoy (carreras/gastos + lecturas km).
    const [{ data: txU }, { data: odU }] = await Promise.all([
      supabase.from('transactions').select('user_id').gte('created_at', todayIso).limit(5000),
      supabase.from('odometer_readings').select('user_id').gte('taken_at', todayIso).limit(5000),
    ]);
    const dau = new Set([...(txU || []), ...(odU || [])].map((r) => r.user_id).filter(Boolean)).size;
    // Transcripciones de voz hoy (suma del contador diario por usuario).
    const { data: trRows } = await supabase.from('users')
      .select('daily_transcription_count').eq('transcription_count_date', todayDate);
    const transcriptionsToday = (trRows || []).reduce((s, r) => s + (r.daily_transcription_count || 0), 0);

    // --- Crecimiento ---
    const newCompaniesToday = await countSince('tenants', 'created_at', todayIso, (q) => q.is('closed_at', null));
    const newDriversToday = await countSince('users', 'created_at', todayIso, (q) => q.eq('role', 'driver'));

    // --- Producto: activación y riesgo (a partir de tenants + actividad) ---
    const { data: tenants } = await supabase.from('tenants')
      .select('id, subscription_status, trial_ends_at, closed_at');
    const live = (tenants || []).filter((t) => !t.closed_at);
    const trialing = live.filter((t) => t.subscription_status === 'trialing'
      && t.trial_ends_at && new Date(t.trial_ends_at).getTime() > now);
    const paying = live.filter((t) => t.subscription_status === 'active' || t.subscription_status === 'past_due');
    const trialsEnding = trialing.filter((t) => new Date(t.trial_ends_at).getTime() - now <= 5 * dayMs).length;
    // Tenants con alguna carrera (activación) y con carrera en 7 días (retención).
    const [{ data: everTx }, { data: recentTx }] = await Promise.all([
      supabase.from('transactions').select('tenant_id').limit(20000),
      supabase.from('transactions').select('tenant_id').gte('created_at', weekAgoIso).limit(20000),
    ]);
    const everSet = new Set((everTx || []).map((r) => r.tenant_id));
    const recentSet = new Set((recentTx || []).map((r) => r.tenant_id));
    const activated = trialing.filter((t) => everSet.has(t.id)).length;
    const activationRate = trialing.length ? Math.round((activated / trialing.length) * 100) : null;
    const atRisk = paying.filter((t) => !recentSet.has(t.id)).length;

    // --- Soporte ---
    const { count: openTickets } = await supabase.from('incidents')
      .select('id', { count: 'exact', head: true }).eq('kind', 'app').eq('status', 'abierta');

    // --- Negocio (€ NUESTROS: Stripe) ---
    const rev = await readGlobalRevenue();
    const business = rev ? {
      revenue_today: Number(((rev.paidToday || 0) / 100).toFixed(2)),
      revenue_mtd: Number(((rev.paidMtd || 0) / 100).toFixed(2)),
      payments_today: rev.countToday || 0,
      refunds_today: Number(((rev.refundedToday || 0) / 100).toFixed(2)),
    } : null;

    return reply.send({
      day: todayDate,
      business,
      usage: { rides_today: ridesToday, dau, transcriptions_today: transcriptionsToday },
      growth: { new_companies_today: newCompaniesToday, new_drivers_today: newDriversToday, trials_ending: trialsEnding },
      product: { activation_rate: activationRate, activated, trialing: trialing.length, at_risk: atRisk, paying: paying.length },
      support: { open_tickets: openTickets || 0 },
    });
  });

  // Todas las incidencias de todas las empresas (con nombre de empresa y autor).
  app.get('/api/v1/admin/incidents', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });

    const status = request.query?.status; // 'abierta' | 'resuelta' | undefined
    // Solo tickets de SOPORTE (kind='app'). Los chats de flota (jefe<->conductor)
    // son privados de la empresa y el admin de plataforma NO los ve.
    let q = supabase
      .from('incidents')
      .select('id, kind, body, status, created_at, tenant_id, user_id, hidden_for_tenant, tenants(name), users(email)')
      .eq('kind', 'app')
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
      .from('incidents').select('tenant_id, status, user_id').eq('id', request.params.id).single();
    if (!inc) return reply.code(404).send({ error: 'Incidencia no encontrada' });
    const { error } = await supabase.from('incident_messages').insert({
      incident_id: request.params.id,
      tenant_id: inc.tenant_id,
      user_id: g.caller.id,
      body: String(body).trim(),
    });
    if (error) return reply.code(400).send({ error: error.message });
    // Avisa al autor del ticket (usuario de la empresa) de la respuesta de soporte.
    if (inc.user_id && inc.user_id !== g.caller.id) {
      await notifyUser(inc.user_id, 'Respuesta de soporte', String(body).trim().slice(0, 140),
        { type: 'support', incidentId: request.params.id });
    }
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

  // Borrar un ticket de soporte (y sus mensajes, por cascada). Solo admin.
  app.delete('/api/v1/admin/incidents/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { error } = await supabase.from('incidents').delete().eq('id', request.params.id);
    if (error) return reply.code(400).send({ error: error.message });
    await logAdminAction(request, g.caller.id, 'incident_delete', 'incident', request.params.id, null);
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
      .select('id, name, solo, subscription_status, plan_id, drivers_limit, trial_ends_at, created_at, closed_at, stripe_customer_id, stripe_subscription_id, join_code')
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

    // Tickets de SOPORTE de la empresa (kind='app'). El chat de flota
    // (jefe<->conductor) vive en fleet_messages y el admin no lo ve; aquí solo
    // salen las incidencias de soporte, igual que en la bandeja global.
    const { data: incidentList } = await supabase
      .from('incidents')
      .select('id, kind, body, status, created_at, users(email)')
      .eq('tenant_id', id)
      .eq('kind', 'app')
      .order('created_at', { ascending: false })
      .limit(100);

    // Datos de SUSCRIPCIÓN (lado TaxiCount, no finanzas del cliente): asientos
    // ocupados y días gratis conseguidos (retos + referidos). Para la ficha.
    const activeDrivers = (users || []).filter((u) => u.role === 'driver' && u.active !== false);
    const freeDays = await freeDaysForTenant(id);
    // Ingresos REALES cobrados a esta empresa (Stripe): total pagado + lo
    // descontado con cupones. Esto NO son las finanzas internas del cliente
    // (sus carreras), sino lo que ELLA nos ha pagado a nosotros. En euros.
    const rev = await readTenantRevenue(tenant.stripe_customer_id);

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
        // Neto real: pagado menos devuelto (reembolsos).
        paid_total: Number(((rev.paid - (rev.refunded || 0)) / 100).toFixed(2)),
        coupon_total: Number((rev.discount / 100).toFixed(2)),
        refund_total: Number(((rev.refunded || 0) / 100).toFixed(2)),
        paid_invoices: rev.count,
        free_days: freeDays.total,
        free_days_challenges: freeDays.challenges,
        free_days_referrals: freeDays.referrals,
        // Crédito de recompensas (reto + referido) aplicado en Stripe, en euros.
        reward_credit_eur: Number((freeDays.total_cents / 100).toFixed(2)),
        reward_credit_challenges_eur: Number((freeDays.challenges_cents / 100).toFixed(2)),
        reward_credit_referrals_eur: Number((freeDays.referrals_cents / 100).toFixed(2)),
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
        .select('id, name, subscription_status, trial_ends_at, drivers_limit, created_at, stripe_customer_id')
        .order('created_at', { ascending: false }),
      supabase.from('users').select('id, tenant_id, active, annual_price_paid, role'),
      supabase.from('subscription_extensions').select('tenant_id, credit_cents').eq('extension_type', 'challenge'),
      supabase.from('referral_milestone_rewards').select('user_id, credit_cents'),
    ]);

    // Crédito de recompensas (retos por tenant, referidos por owner -> tenant), en
    // céntimos: lo que hemos REGALADO como descuento Stripe (no días de trial).
    const ownerTenant = {};
    const seatsByTenant = {};
    for (const u of drivers ?? []) {
      if (u.role === 'owner') ownerTenant[u.id] = u.tenant_id;
      if (u.role === 'driver' && u.active !== false) {
        (seatsByTenant[u.tenant_id] ||= []).push(Number(u.annual_price_paid ?? 15));
      }
    }
    const centsByTenant = {};
    let centsCh = 0;
    let centsRef = 0;
    for (const e of exts ?? []) {
      const c = e.credit_cents ?? 0;
      centsByTenant[e.tenant_id] = (centsByTenant[e.tenant_id] ?? 0) + c;
      centsCh += c;
    }
    for (const m of milestones ?? []) {
      const tid = ownerTenant[m.user_id];
      const c = m.credit_cents ?? 0;
      if (tid) centsByTenant[tid] = (centsByTenant[tid] ?? 0) + c;
      centsRef += c;
    }

    // Dinero REAL pagado por cada empresa (Stripe), agrupando las facturas
    // pagadas por cliente. Sustituye al MRR estimado (proyección por asientos
    // activos): aquí solo hay lo que se ha cobrado de verdad.
    const rev = await readGlobalRevenue();
    const mrrData = await readMrr();
    const byCustomer = rev?.byCustomer ?? {};
    const rows = (tenants ?? []).map((t) => {
      const paying = t.subscription_status === 'active' || t.subscription_status === 'past_due';
      const activeSeats = (seatsByTenant[t.id] ?? []).length;
      const paidCents = t.stripe_customer_id ? (byCustomer[t.stripe_customer_id] || 0) : 0;
      const trialEnds = t.trial_ends_at ? new Date(t.trial_ends_at).getTime() : null;
      const trialDays = (!paying && trialEnds && trialEnds > now)
        ? Math.ceil((trialEnds - now) / dayMs) : null;
      return {
        id: t.id, name: t.name, status: t.subscription_status,
        paid_seats: t.drivers_limit,          // asientos PAGADOS (cantidad Stripe)
        active_seats: activeSeats,             // asientos ocupados (conductores activos)
        paid_total: Number((paidCents / 100).toFixed(2)), // € reales pagados (acumulado)
        trial_days_left: trialDays,
        reward_credit_eur: Number(((centsByTenant[t.id] ?? 0) / 100).toFixed(2)),
      };
    });

    const payingCount = rows.filter((r) => r.status === 'active').length;
    const canceled = rows.filter((r) => r.status === 'canceled').length;
    // Churn = cancelaciones / (activas + canceladas).
    const churn = (payingCount + canceled) > 0
      ? +((canceled / (payingCount + canceled)) * 100).toFixed(1) : 0;
    // Salud recurrente: MRR real (foto ahora, de las subs vivas de Stripe),
    // ARR = MRR×12, ARPA = MRR / empresas que pagan.
    const mrr = Number(((mrrData?.mrr ?? 0) / 100).toFixed(2));
    const arr = Number((mrr * 12).toFixed(2));
    const arpa = payingCount > 0 ? +(mrr / payingCount).toFixed(2) : 0;
    // Caja REAL cobrada (Stripe) por periodo: hoy, este mes (MTD) y total neto.
    const cashToday = Number(((rev?.paidToday ?? 0) / 100).toFixed(2));
    const cashMtd = Number(((rev?.paidMtd ?? 0) / 100).toFixed(2));
    const cashTotal = Number((((rev?.paid ?? 0) - (rev?.refunded ?? 0)) / 100).toFixed(2));

    return reply.send({
      totals: {
        mrr, arr, arpa,              // salud recurrente (€/mes, €/año, €/empresa·mes)
        cash_today: cashToday,       // € cobrados hoy
        cash_mtd: cashMtd,           // € cobrados este mes
        cash_total: cashTotal,       // € cobrados neto (acumulado histórico)
        paying: payingCount,
        past_due: rows.filter((r) => r.status === 'past_due').length,
        trialing: rows.filter((r) => r.trial_days_left != null).length,
        canceled,
        churn, // %
        reward_credit_total_eur: Number(((centsCh + centsRef) / 100).toFixed(2)),
        reward_credit_challenges_eur: Number((centsCh / 100).toFixed(2)),
        reward_credit_referrals_eur: Number((centsRef / 100).toFixed(2)),
      },
      past_due: rows.filter((r) => r.status === 'past_due'),
      trials: rows.filter((r) => r.trial_days_left != null)
        .sort((a, b) => a.trial_days_left - b.trial_days_left),
      paying: rows.filter((r) => r.status === 'active')
        .sort((a, b) => b.paid_total - a.paid_total),
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
    // Atajo: SUMAR (o restar, con negativo) N días a la prueba. Base = el fin de
    // prueba actual si aún es futuro; si ya pasó, ahora. Así +N amplía y -N quita
    // días (si se resta más de lo que queda, la prueba queda caducada).
    if (b.extend_trial_days !== undefined && b.extend_trial_days !== null) {
      const days = Number(b.extend_trial_days);
      if (!Number.isNaN(days) && days !== 0) {
        const { data: cur } = await supabase.from('tenants')
          .select('trial_ends_at').eq('id', request.params.id).maybeSingle();
        const curEnd = cur?.trial_ends_at ? new Date(cur.trial_ends_at).getTime() : 0;
        const base = Math.max(Date.now(), curEnd);
        patch.trial_ends_at = new Date(base + days * 86400000).toISOString();
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

  // CIERRE LÓGICO de una empresa con retención fiscal (5 años): NO borra la
  // empresa (eso borraría en cascada sus carreras). Marca closed_at, anonimiza,
  // cancela la suscripción en Stripe (si cancelStripe) y elimina las cuentas de
  // acceso; las carreras quedan (user_id -> null) y se purgan a los 5 años
  // (purge_expired_retention). Lo usan el cierre del admin y la baja del propio
  // owner. Un admin de plataforma NUNCA pierde su cuenta: solo se le desvincula.
  async function closeTenantAccount(id, { cancelStripe } = {}) {
    if (cancelStripe && stripe) {
      const { data: t } = await supabase.from('tenants')
        .select('stripe_subscription_id').eq('id', id).maybeSingle();
      if (t?.stripe_subscription_id) {
        try { await stripe.subscriptions.cancel(t.stripe_subscription_id); }
        catch (e) { app.log.warn(`[close] cancel stripe ${id}: ${e.message}`); }
      }
    }
    const { data: users } = await supabase.from('users').select('id, is_admin').eq('tenant_id', id);
    const { error } = await supabase.from('tenants').update({
      closed_at: new Date().toISOString(),
      name: 'Empresa dada de baja',
      subscription_status: 'canceled',
      stripe_customer_id: null,
      stripe_subscription_id: null,
      join_code: null,
    }).eq('id', id);
    if (error) throw new Error(error.message);
    let removed = 0;
    for (const u of users || []) {
      if (u.is_admin) {
        await supabase.from('users').update({ tenant_id: null }).eq('id', u.id);
        continue;
      }
      try { await supabase.auth.admin.deleteUser(u.id); } catch (_) {}
      removed += 1;
    }
    return { removed };
  }

  // Eliminar una empresa entera (admin): cierre lógico + eliminación de accesos.
  app.delete('/api/v1/admin/company/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const id = request.params.id;
    let removed = 0;
    try { ({ removed } = await closeTenantAccount(id, { cancelStripe: false })); }
    catch (e) { return reply.code(400).send({ error: e.message }); }
    await logAdminAction(request, g.caller.id, 'company_close', 'tenant', id,
      { removed_access: removed });
    return reply.send({ ok: true, closed: true, removed_access: removed });
  });

  // Baja de la propia empresa (el OWNER cierra su cuenta). Cancela la suscripción
  // en Stripe, marca la empresa como dada de baja (retención GDPR 5 años) y
  // elimina los accesos (incluido el suyo). Exige confirmar escribiendo el nombre
  // de la empresa para evitar accidentes. Irreversible desde la app.
  app.post('/api/v1/company/close', async (request, reply) => {
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (caller.role !== 'owner') return reply.code(403).send({ error: 'Solo el propietario puede dar de baja la empresa' });
    const { data: t } = await supabase.from('tenants')
      .select('id, name, closed_at').eq('id', caller.tenant_id).maybeSingle();
    if (!t) return reply.code(404).send({ error: 'Empresa no encontrada' });
    if (t.closed_at) return reply.code(400).send({ error: 'La empresa ya está dada de baja' });
    const confirmName = String((request.body ?? {}).confirm_name ?? '').trim();
    if (confirmName.toLowerCase() !== String(t.name || '').trim().toLowerCase()) {
      return reply.code(400).send({ code: 'name_mismatch', error: 'El nombre de la empresa no coincide' });
    }
    try {
      const { removed } = await closeTenantAccount(caller.tenant_id, { cancelStripe: true });
      return reply.send({ ok: true, removed_access: removed });
    } catch (e) {
      return reply.code(500).send({ error: e.message });
    }
  });

  // Purga DEFINITIVA de UNA empresa YA dada de baja: borra el tenant y, en
  // cascada, todos sus datos (carreras, vehículos, retos, lecturas…). Irreversible.
  // Guarda contra borrar una empresa activa: exige closed_at (dada de baja).
  // Pensado para limpiar empresas de prueba sin esperar la retención de 5 años.
  app.delete('/api/v1/admin/company/:id/purge', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const id = request.params.id;
    const { data: t } = await supabase.from('tenants')
      .select('id, name, closed_at').eq('id', id).maybeSingle();
    if (!t) return reply.code(404).send({ error: 'Empresa no encontrada' });
    if (!t.closed_at) {
      return reply.code(400).send({ error: 'Solo se pueden purgar empresas dadas de baja' });
    }
    // Desvincula (por si acaso) cualquier admin de plataforma que siga apuntando
    // a este tenant, para no borrar su cuenta con la cascada.
    await supabase.from('users').update({ tenant_id: null }).eq('tenant_id', id).eq('is_admin', true);
    const { error } = await supabase.from('tenants').delete().eq('id', id);
    if (error) return reply.code(400).send({ error: error.message });
    await logAdminAction(request, g.caller.id, 'company_purge', 'tenant', id, { name: t.name });
    return reply.send({ ok: true, purged: true });
  });

  // REACTIVAR una empresa dada de baja (antes de purgarla): la baja eliminó las
  // cuentas de acceso pero conservó los datos (retención). Esto deshace el cierre
  // lógico (closed_at), restaura el nombre (la baja lo anonimizó), regenera el
  // código de flota, da un periodo de prueba para que pueda re-suscribirse y CREA
  // la cuenta del owner con contraseña temporal (el trigger de alta la vincula al
  // tenant existente vía metadata). Los datos históricos (carreras, vehículos…)
  // reaparecen; los conductores deben re-invitarse (sus cuentas se eliminaron).
  // Reinicia el cupón de bienvenida de una empresa: borra coupon_redeemed_code,
  // así vuelve a verse el aviso del cupón activo (útil para pruebas y soporte;
  // un refund de Stripe NO toca esta columna de la app). Auditado.
  app.post('/api/v1/admin/company/:id/reset-welcome-coupon', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const id = request.params.id;
    const { error } = await supabase.from('tenants')
      .update({ coupon_redeemed_code: null }).eq('id', id);
    if (error) return reply.code(500).send({ error: error.message });
    await logAdminAction(request, g.caller?.id ?? null, 'reset_welcome_coupon', 'tenant', id, null);
    return reply.send({ ok: true });
  });

  // ── PRUEBAS (solo admin): dispara la recompensa de UNA empresa, SIN tocar la
  // config global ni ejecutar los crons globales -> seguro con usuarios reales
  // dentro. mode 'challenge' siembra un reto completado y aplica su crédito; mode
  // 'referrals' valida AHORA (ignorando los 15d) los referidos de su owner y
  // recalcula hitos. Requiere que la empresa YA PAGUE (si no, se difiere).
  app.post('/api/v1/admin/company/:id/test-rewards', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const id = request.params.id;
    const mode = String((request.body ?? {}).mode ?? '').trim();
    const out = { ok: true, mode };

    const { data: tenant } = await supabase.from('tenants')
      .select('id, stripe_customer_id, stripe_subscription_id, drivers_limit').eq('id', id).maybeSingle();
    if (!tenant) return reply.code(404).send({ error: 'Empresa no encontrada' });

    if (mode === 'challenge') {
      // 1) Sembrar un reto COMPLETADO (rewarded) para un conductor/owner de esta empresa.
      const { data: member } = await supabase.from('users')
        .select('id').eq('tenant_id', id).order('role', { ascending: true }).limit(1).maybeSingle();
      if (!member?.id) return reply.code(400).send({ error: 'La empresa no tiene usuarios' });
      const challenge = 'money_100k';
      const { data: prev } = await supabase.from('challenge_claims')
        .select('level, status, metric_value').eq('user_id', member.id).eq('challenge', challenge);
      const st = levelState(prev ?? []);
      const ins = await supabase.from('challenge_claims').insert({
        tenant_id: id, user_id: member.id, challenge, level: st.level,
        baseline: st.baseline, target: 1, metric_value: st.baseline + 1, active_days: 0,
        suspicious: false, status: 'rewarded', reviewed_at: new Date().toISOString(),
      });
      out.seeded = !ins.error;
      if (ins.error) out.seed_error = ins.error.message;
      // 2) Aplicar el crédito SOLO de esta empresa.
      out.challenge = await applyPendingChallengeCredits(id);
    } else if (mode === 'referrals') {
      // Validar AHORA (ignorando los 15d) los referidos pendientes cuyo padrino sea
      // el owner de esta empresa, y recalcular sus hitos. Todo scoped a este owner.
      const { data: owner } = await supabase.from('users')
        .select('id').eq('tenant_id', id).eq('role', 'owner').maybeSingle();
      if (!owner?.id) return reply.code(400).send({ error: 'La empresa no tiene owner' });
      out.referral = await processReferralValidationQueue({ referrerUserId: owner.id, force: true });
      await recomputeReferrerMilestones(owner.id); // por si ya había válidos sin hito aplicado
    } else {
      return reply.code(400).send({ error: 'mode debe ser challenge o referrals' });
    }

    // Desglose de la tarifa de flota (debug): qué líneas de factura cuenta y su
    // aportación mensual, para verificar el cálculo del crédito.
    if (stripe && tenant.stripe_customer_id) {
      const fleetDbg = [];
      out.fleet_monthly_eur = +(
        (await fleetMonthlyCents(tenant.stripe_customer_id, tenant.stripe_subscription_id, fleetDbg)) / 100
      ).toFixed(2);
      out.seats = (await subscriptionSeats(tenant.stripe_subscription_id)) || tenant.drivers_limit;
      out.drivers_limit = tenant.drivers_limit;
      out.fleet_lines = fleetDbg;
      // Saldo actual del cliente (negativo = crédito pendiente de consumir).
      try {
        const cust = await stripe.customers.retrieve(tenant.stripe_customer_id);
        out.customer_balance_cents = cust?.balance ?? 0;
      } catch { /* sin balance */ }
    }
    await logAdminAction(request, g.caller?.id ?? null, 'test_rewards', 'tenant', id, out);
    return reply.send(out);
  });

  app.post('/api/v1/admin/company/:id/reactivate', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const id = request.params.id;
    const b = request.body ?? {};
    const ownerEmail = String(b.owner_email ?? '').trim().toLowerCase();
    const companyName = String(b.company_name ?? '').trim();
    const trialDays = Math.min(60, Math.max(1, Math.trunc(Number(b.trial_days)) || 15));
    if (!ownerEmail || !ownerEmail.includes('@')) {
      return reply.code(400).send({ error: 'Correo del propietario inválido' });
    }
    if (!companyName) return reply.code(400).send({ error: 'El nombre de la empresa es obligatorio' });

    const { data: t } = await supabase.from('tenants')
      .select('id, name, closed_at').eq('id', id).maybeSingle();
    if (!t) return reply.code(404).send({ error: 'Empresa no encontrada' });
    if (!t.closed_at) return reply.code(400).send({ error: 'La empresa no está dada de baja' });

    // El correo no puede pertenecer ya a otra cuenta (misma pre-comprobación que
    // al invitar conductores: sin esto el trigger falla con un error confuso).
    const { data: dup } = await supabase.from('users')
      .select('id').ilike('email', ownerEmail).maybeSingle();
    if (dup) return reply.code(409).send({ error: 'Ese correo ya está registrado en TaxiCount; usa otro.' });

    // 1) Reabrir el tenant: quitar closed_at, restaurar nombre, nueva prueba y
    //    código de flota nuevo (con reintentos por si colisiona el unique).
    let joinCode = null;
    for (let i = 0; i < 5 && !joinCode; i++) {
      const code = randomBytes(4).toString('hex').slice(0, 6).toUpperCase();
      const { error } = await supabase.from('tenants').update({
        closed_at: null,
        name: companyName,
        subscription_status: 'trialing',
        trial_ends_at: new Date(Date.now() + trialDays * 86400000).toISOString(),
        join_code: code,
      }).eq('id', id);
      if (!error) joinCode = code;
      else if (!/duplicate|unique|23505/i.test(error.message || '')) {
        return reply.code(400).send({ error: error.message });
      }
    }
    if (!joinCode) return reply.code(500).send({ error: 'No se pudo generar el código de flota' });

    // 2) Crear la cuenta del owner vinculada al tenant (metadata -> trigger).
    const tempPassword = generateTempPassword();
    const { data: created, error: createErr } = await supabase.auth.admin.createUser({
      email: ownerEmail,
      password: tempPassword,
      email_confirm: true,
      user_metadata: { role: 'owner', tenant_id: id, name: b.owner_name ?? null },
    });
    if (createErr) {
      // Deshacer la reapertura para no dejar una empresa abierta sin owner.
      await supabase.from('tenants').update({
        closed_at: t.closed_at, name: t.name, join_code: null, trial_ends_at: null,
        subscription_status: 'canceled',
      }).eq('id', id);
      return reply.code(400).send({ error: createErr.message || 'No se pudo crear la cuenta del owner' });
    }
    await supabase.from('users').update({ must_change_password: true }).eq('id', created.user.id);

    await logAdminAction(request, g.caller.id, 'company_reactivate', 'tenant', id,
      { owner_email: ownerEmail, trial_days: trialDays });
    app.log.info(`[reactivate] tenant ${id} reabierto; owner ${ownerEmail}`);
    return reply.send({ ok: true, owner_email: ownerEmail, tempPassword, join_code: joinCode, trial_days: trialDays });
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
  // ¿El tenant es cliente DE PAGO? Las recompensas (mes de retos / días de
  // referidos) solo se aplican sobre una suscripción activa; durante la PRUEBA
  // se difieren (no tiene sentido alargar una prueba que ya es gratis).
  async function tenantIsPaying(tenantId) {
    const { data: t } = await supabase.from('tenants')
      .select('subscription_status').eq('id', tenantId).maybeSingle();
    return t?.subscription_status === 'active' || t?.subscription_status === 'past_due';
  }

  // Coste MENSUAL efectivo de la flota (céntimos), NETO de descuentos, leído de las
  // facturas de Stripe realmente pagadas y VIGENTES hoy (su periodo cubre "ahora").
  // Suma cada factura vigente / sus meses, así que si hay asientos pagados a precios
  // distintos (p. ej. 1er asiento con cupón de bienvenida + 2o a precio pleno en su
  // prorrateo), se SUMAN automáticamente sin reconstruir historial por asiento. Es la
  // base de las recompensas: reto = 1 asiento·mes; referido = N días de flota.
  // Devuelve 0 si no hay factura vigente (p. ej. en prueba, sin suscripción todavía).
  async function fleetMonthlyCents(customerId, subscriptionId = null, details = null) {
    if (!stripe || !customerId) return 0;
    const nowS = Math.floor(Date.now() / 1000);
    let monthly = 0;
    try {
      for await (const inv of stripe.invoices.list({ customer: customerId, status: 'paid', limit: 100 })) {
        // `subscription` a nivel factura está deprecado en API nuevas: la suscripción
        // real puede vivir en inv.parent.subscription_details.subscription o en las
        // líneas (line.subscription / line.parent...). Miramos todas las fuentes.
        const invSub = (typeof inv.subscription === 'string' ? inv.subscription : inv.subscription?.id)
          ?? inv.parent?.subscription_details?.subscription
          ?? (inv.lines?.data ?? []).map((l) => (typeof l.subscription === 'string' ? l.subscription : l.subscription?.id)
              ?? l.parent?.subscription_item_details?.subscription).find(Boolean);
        // Solo la suscripción ACTIVA: en cuentas de prueba quedan facturas de subs
        // viejas cuyo periodo aún "cubre hoy" y, sumadas, inflaban el coste.
        const subOk = !subscriptionId || !invSub || invSub === subscriptionId;
        const subtotal = inv.subtotal || 0;
        const netRatio = subtotal > 0 ? (inv.amount_paid || 0) / subtotal : 0;
        if (details) details.push(`INV ${inv.number ?? inv.id} paid=${((inv.amount_paid || 0) / 100).toFixed(2)} reason=${inv.billing_reason ?? '?'} sub=${invSub ? invSub.slice(-6) : 'none'} subOk=${subOk} net=${netRatio.toFixed(2)}`);
        if (!subOk || netRatio <= 0) continue;
        for (const line of inv.lines?.data ?? []) {
          // El periodo de SERVICIO vive en las LÍNEAS (line.period), no en la factura.
          const ps = line.period?.start;
          const pe = line.period?.end;
          const covers = !!(ps && pe && pe > ps && ps <= nowS && nowS < pe);
          let months = (ps && pe && pe > ps) ? (pe - ps) / (30.44 * 86400) : 0;
          const snap = Math.round(months);
          if (snap >= 1 && Math.abs(months - snap) / snap < 0.08) months = snap;
          const contrib = (covers && months > 0) ? ((line.amount || 0) * netRatio) / months : 0;
          monthly += contrib;
          if (details) details.push(`  ln qty=${line.quantity ?? '?'} amt=${((line.amount || 0) / 100).toFixed(2)} covers=${covers} m=${months.toFixed(1)} -> ${(contrib / 100).toFixed(2)}`);
        }
      }
    } catch (e) {
      app.log.warn(`[reward] fleetMonthlyCents ${customerId}: ${e.message}`);
      if (details) details.push(`ERROR ${e.message}`);
      return 0;
    }
    return Math.round(monthly);
  }

  // Nº de asientos REALES de la suscripción activa (fuente de verdad = Stripe, no
  // drivers_limit, que en cuentas de prueba puede quedar desincronizado). Se usa
  // para el reto (1 asiento medio = coste_flota / asientos), consistente con lo que
  // fleetMonthlyCents cuenta de esa misma suscripción.
  async function subscriptionSeats(subscriptionId) {
    if (!stripe || !subscriptionId) return 0;
    try {
      const sub = await stripe.subscriptions.retrieve(subscriptionId);
      return (sub.items?.data ?? []).reduce((s, it) => s + (it.quantity ?? 0), 0);
    } catch (e) {
      app.log.warn(`[reward] subscriptionSeats ${subscriptionId}: ${e.message}`);
      return 0;
    }
  }

  // Crédito de recompensa: aplica un saldo NEGATIVO al cliente en Stripe, que se
  // consume automáticamente en su PRÓXIMA factura. Devuelve el id de la transacción
  // (para poder revertirla en un clawback) o null si no se aplicó.
  async function applyRewardCredit(customerId, cents, description) {
    if (!stripe || !customerId || !(cents > 0)) return null;
    try {
      const txn = await stripe.customers.createBalanceTransaction(customerId, {
        amount: -Math.round(cents), currency: 'eur', description,
      });
      return txn.id;
    } catch (e) {
      app.log.warn(`[reward] applyRewardCredit ${customerId}: ${e.message}`);
      return null;
    }
  }

  // Clawback (opción b): retira el crédito que AÚN NO se haya consumido; si ya se
  // gastó (el saldo del cliente ya no lo cubre), se asume la pérdida y NO se cobra
  // de más al cliente. Nunca deja el saldo en positivo (nunca genera un cargo).
  async function reverseRewardCredit(customerId, cents) {
    if (!stripe || !customerId || !(cents > 0)) return 0;
    try {
      const cust = await stripe.customers.retrieve(customerId);
      const bal = cust?.balance ?? 0; // negativo = crédito disponible
      const reverse = Math.min(Math.round(cents), Math.max(0, -bal));
      if (reverse <= 0) return 0;
      await stripe.customers.createBalanceTransaction(customerId, {
        amount: reverse, currency: 'eur', description: 'Clawback recompensa referido',
      });
      return reverse;
    } catch (e) {
      app.log.warn(`[reward] reverseRewardCredit ${customerId}: ${e.message}`);
      return 0;
    }
  }

  async function applyPendingChallengeCredits(onlyTenantId = null) {
    let cq = supabase
      .from('challenge_claims')
      .select('id, tenant_id, user_id, challenge')
      .eq('status', 'rewarded')
      .is('reward_redeemed_at', null)
      .limit(1000);
    if (onlyTenantId) cq = cq.eq('tenant_id', onlyTenantId);
    const { data: claims } = await cq;
    let rewarded = 0;
    let deferred = 0;
    let skipped = 0;
    for (const c of claims ?? []) {
      // Solo se premia si la empresa ya es de PAGO. En prueba se deja pendiente
      // (sin marcar canjeado) y el cron lo aplicará cuando pase a suscripción.
      if (!(await tenantIsPaying(c.tenant_id))) { deferred++; continue; }
      // Recompensa del reto = 1 ASIENTO · 1 MES, valorado a la tarifa EFECTIVA por
      // asiento del último pago (neto de cupón). Con asientos a precios distintos se
      // usa el asiento MEDIO: coste_mensual_flota / asientos. Se aplica como crédito
      // Stripe que se consume en la PRÓXIMA factura (no extiende trial_ends_at).
      const { data: tRow } = await supabase.from('tenants')
        .select('stripe_customer_id, stripe_subscription_id, drivers_limit').eq('id', c.tenant_id).maybeSingle();
      const subSeats = await subscriptionSeats(tRow?.stripe_subscription_id);
      const seats = Math.max(1, subSeats || Number(tRow?.drivers_limit ?? 1));
      const fleetM = await fleetMonthlyCents(tRow?.stripe_customer_id, tRow?.stripe_subscription_id);
      const creditCents = Math.round(fleetM / seats);
      try {
        const now = new Date();
        const txnId = creditCents > 0
          ? await applyRewardCredit(tRow?.stripe_customer_id, creditCents, `Reto completado (${c.challenge ?? ''})`)
          : null;
        await supabase.from('subscription_extensions').insert({
          user_id: c.user_id, tenant_id: c.tenant_id, extension_type: 'challenge',
          source_id: c.id, days_extended: 0, credit_cents: creditCents, stripe_txn_id: txnId,
          monthly_value: (creditCents / 100).toFixed(2), extended_until: now.toISOString(),
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
      .select('days_extended, credit_cents').eq('tenant_id', tenantId).eq('extension_type', 'challenge');
    const challenges = (exts ?? []).reduce((s, r) => s + (r.days_extended ?? 0), 0);
    const challengesCents = (exts ?? []).reduce((s, r) => s + (r.credit_cents ?? 0), 0);
    const { data: owners } = await supabase.from('users')
      .select('id').eq('tenant_id', tenantId).eq('role', 'owner');
    const ownerIds = (owners ?? []).map((o) => o.id);
    let referrals = 0;
    let referralsCents = 0;
    if (ownerIds.length) {
      const { data: rr } = await supabase.from('referral_milestone_rewards')
        .select('days_awarded, credit_cents').in('user_id', ownerIds);
      referrals = (rr ?? []).reduce((s, r) => s + (r.days_awarded ?? 0), 0);
      referralsCents = (rr ?? []).reduce((s, r) => s + (r.credit_cents ?? 0), 0);
    }
    return {
      challenges, referrals, total: challenges + referrals,
      challenges_cents: challengesCents, referrals_cents: referralsCents,
      total_cents: challengesCents + referralsCents,
    };
  }

  app.post('/api/v1/admin/cron/apply-challenge-credits', async (request, reply) => {
    const g = await cronOrAdmin(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const res = await applyPendingChallengeCredits();
    await markCronRun('challenge_credits');
    await logAdminAction(request, g.caller?.id ?? null, 'challenge_credits_apply', 'challenge_claims', null, res);
    return reply.send({ ok: true, ...res });
  });

  // Recordatorios de MANTENIMIENTO de vehículos: avisa por push al/los owner(s)
  // cuando se acerca una fecha (ITV, ITV taxímetro, seguro, tarjeta de
  // transporte) o la revisión por km. Un cron DIARIO lo llama con x-cron-secret.
  // Hitos: 30/15/7/1 días, el día y caducado; ~1000/~200/0 km. Cada aviso UNA
  // vez (tabla maintenance_reminders_sent). Idempotente.
  app.post('/api/v1/admin/cron/maintenance-reminders', async (request, reply) => {
    const g = await cronOrAdmin(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const res = await runMaintenanceReminders();
    await markCronRun('maintenance_reminders');
    return reply.send({ ok: true, ...res });
  });

  // Días que faltan hasta una fecha (date-only, en UTC; margen de ±1 día por tz
  // es aceptable para un recordatorio diario).
  function daysUntilDate(dateStr) {
    if (!dateStr) return null;
    const d = new Date(`${String(dateStr).slice(0, 10)}T00:00:00Z`);
    if (Number.isNaN(d.getTime())) return null;
    const n = new Date();
    const today = Date.UTC(n.getUTCFullYear(), n.getUTCMonth(), n.getUTCDate());
    return Math.round((d.getTime() - today) / 86400000);
  }
  // Un solo hito por día (ventanas), para no saturar aunque se dé de alta tarde.
  function dateMilestone(daysLeft) {
    if (daysLeft < 0) return 'expired';
    if (daysLeft === 0) return '0';
    if (daysLeft === 1) return '1';
    if (daysLeft <= 7) return '7';
    if (daysLeft <= 15) return '15';
    if (daysLeft <= 30) return '30';
    return null;
  }
  function kmMilestone(kmLeft) {
    if (kmLeft <= 0) return 'km0';
    if (kmLeft <= 200) return 'km200';
    if (kmLeft <= 1000) return 'km1000';
    return null;
  }
  const _cap = (s) => (s ? s.charAt(0).toUpperCase() + s.slice(1) : s);
  const _fmtD = (iso) => { const p = String(iso).slice(0, 10).split('-'); return p.length === 3 ? `${p[2]}/${p[1]}/${p[0]}` : iso; };

  // Registra un aviso (vehicle,kind,ref,milestone). Devuelve true si es NUEVO
  // (no se había enviado) -> hay que mandar el push.
  async function recordMaintReminder(vehicleId, kind, ref, milestone) {
    const { data } = await supabase.from('maintenance_reminders_sent')
      .upsert({ vehicle_id: vehicleId, kind, ref: String(ref), milestone: String(milestone) },
        { onConflict: 'vehicle_id,kind,ref,milestone', ignoreDuplicates: true })
      .select('id');
    return !!(data && data.length);
  }
  // Km actuales del vehículo: máx de km inicial/registrado, lecturas de jornada
  // y odómetro apuntado en carreras.
  async function vehicleCurrentKm(v) {
    let best = Math.max(Number(v.initial_odometer || 0), Number(v.registered_km || 0));
    const { data: r } = await supabase.from('odometer_readings')
      .select('reading_km').eq('vehicle_id', v.id).order('reading_km', { ascending: false }).limit(1);
    if (r && r[0]?.reading_km != null) best = Math.max(best, Number(r[0].reading_km));
    const { data: t } = await supabase.from('transactions')
      .select('odometer_km').eq('vehicle_id', v.id).not('odometer_km', 'is', null)
      .order('odometer_km', { ascending: false }).limit(1);
    if (t && t[0]?.odometer_km != null) best = Math.max(best, Number(t[0].odometer_km));
    return best;
  }

  async function runMaintenanceReminders() {
    if (!pushEnabled()) return { push: false, sent: 0 };
    const { data: owners } = await supabase.from('users')
      .select('id, tenant_id').eq('role', 'owner').eq('active', true);
    const ownersByTenant = {};
    for (const o of owners || []) (ownersByTenant[o.tenant_id] ||= []).push(o.id);

    const { data: vehicles } = await supabase.from('vehicles')
      .select('id, tenant_id, license_plate, model, active, itv_expiry, taximeter_itv_expiry, insurance_expiry, transport_card_date, transport_card_years, revision_interval_km, last_revision_km, initial_odometer, registered_km')
      .eq('active', true);

    let sent = 0;
    for (const v of vehicles || []) {
      const ownerIds = ownersByTenant[v.tenant_id];
      if (!ownerIds || !ownerIds.length) continue;
      const label = v.license_plate || v.model || 'Vehículo';

      const items = [];
      if (v.itv_expiry) items.push(['itv', 'ITV', v.itv_expiry]);
      if (v.taximeter_itv_expiry) items.push(['taximeter_itv', 'ITV del taxímetro', v.taximeter_itv_expiry]);
      if (v.insurance_expiry) items.push(['insurance', 'seguro', v.insurance_expiry]);
      if (v.transport_card_date) {
        const base = new Date(`${String(v.transport_card_date).slice(0, 10)}T00:00:00Z`);
        if (!Number.isNaN(base.getTime())) {
          base.setUTCFullYear(base.getUTCFullYear() + (Number(v.transport_card_years) || 4));
          items.push(['transport_card', 'tarjeta de transporte', base.toISOString().slice(0, 10)]);
        }
      }
      for (const [kind, kindLabel, dueDate] of items) {
        const daysLeft = daysUntilDate(dueDate);
        if (daysLeft == null) continue;
        const m = dateMilestone(daysLeft);
        if (!m) continue;
        if (!await recordMaintReminder(v.id, kind, dueDate, m)) continue;
        let title, body;
        if (m === 'expired') {
          title = '⚠️ Mantenimiento caducado';
          body = `${label}: ${_cap(kindLabel)} venció el ${_fmtD(dueDate)}. Conviene renovarlo.`;
        } else if (m === '0') {
          title = '⏰ Mantenimiento: vence hoy';
          body = `${label}: ${_cap(kindLabel)} vence hoy (${_fmtD(dueDate)}).`;
        } else {
          title = '⏰ Mantenimiento próximo';
          body = `${label}: ${_cap(kindLabel)} vence en ${daysLeft} día(s) (${_fmtD(dueDate)}).`;
        }
        await notifyUsers(ownerIds, title, body, { type: 'maintenance', vehicleId: v.id });
        sent++;
      }

      if (v.last_revision_km != null && v.revision_interval_km) {
        const target = Number(v.last_revision_km) + Number(v.revision_interval_km);
        const current = await vehicleCurrentKm(v);
        if (current != null) {
          const kmLeft = target - current;
          const m = kmMilestone(kmLeft);
          if (m && await recordMaintReminder(v.id, 'revision_km', String(target), m)) {
            const title = '🔧 Revisión de mantenimiento';
            const body = kmLeft > 0
              ? `${label}: faltan ~${kmLeft} km para la próxima revisión (a los ${target} km).`
              : `${label}: toca revisión (has superado los ${target} km).`;
            await notifyUsers(ownerIds, title, body, { type: 'maintenance', vehicleId: v.id });
            sent++;
          }
        }
      }
    }
    return { push: true, sent };
  }

  // Marca que la copia de seguridad diaria de la BD se realizó correctamente.
  // Lo llama el workflow "Backup diario de la BD" (backup-db.yml) al terminar el
  // pg_dump con éxito, con la cabecera x-cron-secret. Solo registra el sello de
  // tiempo (cron_last_backup) para que el semáforo del panel de admin lo muestre;
  // no toca datos. Idempotente.
  app.post('/api/v1/admin/cron/backup-done', async (request, reply) => {
    const g = await cronOrAdmin(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    await markCronRun('backup');
    return reply.send({ ok: true, at: new Date().toISOString() });
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
      .select('id, tenant_id, user_id, body, kind')
      .eq('id', incidentId)
      .single();
    if (!inc || inc.tenant_id !== caller.tenant_id) {
      return reply.code(404).send({ error: 'Incidencia no encontrada' });
    }

    // Destinatarios:
    //  - ticket de SOPORTE (kind='app'): avisar a los ADMINS de plataforma.
    //  - incidencia interna: si escribe el conductor -> owners; si el owner -> autor.
    // Nunca te notificas a ti mismo.
    let recipientIds;
    if (inc.kind === 'app') {
      recipientIds = await platformAdminIds();
    } else if (caller.role === 'owner') {
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

    const support = inc.kind === 'app';
    const title = support
      ? (kind === 'new_message' ? 'Nuevo mensaje de soporte' : 'Nuevo ticket de soporte')
      : (kind === 'new_message' ? 'Nuevo mensaje de incidencia' : 'Nueva incidencia');
    const text = (body || inc.body || '').toString().slice(0, 140);
    const result = await sendToTokens(
      tokens,
      { title, body: text, data: { type: support ? 'support' : 'incident', incidentId: inc.id } },
      request.log,
    );
    if (result.attempted) markService('push', result.ok);

    if (result.invalidTokens.length > 0) {
      await supabase.from('device_tokens').delete().in('token', result.invalidTokens);
    }
    return reply.send({ ok: true, push: true, sent: result.sent });
  });

  // --- Notificación push de un mensaje del chat de flota (jefe <-> conductor) ---
  // La app lo llama tras insertar el mensaje (por RLS) para avisar a la otra
  // parte. El admin de plataforma NO participa en este canal.
  app.post('/api/v1/notify-fleet-message', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (!pushEnabled()) return reply.send({ ok: true, push: false });

    const b = request.body ?? {};
    const driverId = String(b.driver_id ?? '');
    const text = String(b.body ?? '').slice(0, 140);
    if (!driverId) return reply.code(400).send({ error: 'driver_id es obligatorio' });

    // Nombre del remitente (para el título del aviso).
    const { data: me } = await supabase.from('users')
      .select('name, display_name, email').eq('id', caller.id).maybeSingle();
    const senderName = me?.display_name || me?.name || me?.email || '';

    let recipientIds;
    let title;
    if (caller.role === 'owner') {
      // Jefe -> ese conductor. Muestra el NOMBRE del jefe, no "tu jefe".
      recipientIds = [driverId];
      title = senderName ? `Mensaje de ${senderName}` : 'Mensaje de tu jefe';
    } else {
      // Conductor -> jefe(s) de su tenant.
      const { data: owners } = await supabase.from('users')
        .select('id').eq('tenant_id', caller.tenant_id).eq('role', 'owner');
      recipientIds = (owners || []).map((o) => o.id);
      title = senderName ? `Mensaje de ${senderName}` : 'Mensaje de un conductor';
    }
    recipientIds = (recipientIds || []).filter((id) => id && id !== caller.id);
    // driverName solo es útil cuando escribe el conductor (para que el jefe abra
    // el chat con su nombre); el conductor que recibe lo ignora.
    await notifyUsers(recipientIds, title, text,
      { type: 'fleet', driverId, driverName: caller.role === 'owner' ? '' : senderName });
    return reply.send({ ok: true, push: true });
  });

  // Nombre del jefe (owner) del tenant del que pregunta. Para que el conductor
  // vea el NOMBRE real del jefe en el chat (no puede leer la fila del owner por
  // RLS). Vía service_role. Cualquier miembro autenticado del tenant.
  app.get('/api/v1/fleet/boss-name', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (!caller.tenant_id) return reply.send({ name: '' });
    const { data: owner } = await supabase.from('users')
      .select('name, display_name, email').eq('tenant_id', caller.tenant_id)
      .eq('role', 'owner').order('created_at', { ascending: true }).limit(1).maybeSingle();
    const name = owner?.display_name || owner?.name || owner?.email || '';
    return reply.send({ name });
  });

  // Nº de asientos (conductores) a facturar de un tenant. Mínimo 1: incluso un
  // autónomo sin conductores extra ocupa 1 asiento (él mismo).
  async function seatCount(tenantId) {
    const { count } = await supabase.from('users')
      .select('id', { count: 'exact', head: true })
      .eq('tenant_id', tenantId).eq('role', 'driver').eq('active', true);
    return Math.max(1, count ?? 0);
  }

  // Fija la CANTIDAD de asientos pagados en la suscripción de Stripe. Al AÑADIR
  // factura YA la parte proporcional (always_invoice): en el plan ANUAL, con el
  // prorrateo por defecto el asiento nuevo no se cobraría hasta la renovación
  // (~1 año). Al QUITAR, deja el crédito para la próxima factura. Devuelve la
  // cantidad efectiva. Lanza si Stripe falla (el endpoint lo traduce a error).
  async function setSeatQuantity(tenantId, seats) {
    const { data: t } = await supabase.from('tenants')
      .select('stripe_subscription_id, subscription_status').eq('id', tenantId).maybeSingle();
    const subId = t?.stripe_subscription_id;
    if (!subId) throw new Error('sin suscripción activa');
    const sub = await stripe.subscriptions.retrieve(subId, { expand: ['items.data.price'] });
    const item = sub.items?.data?.[0];
    if (!item) throw new Error('suscripción sin item');
    const prev = item.quantity ?? 0;
    if (prev === seats) {
      return { seats, prev, amount: 0, charged: false, reason: 'Stripe ya tenía esa cantidad (nada que cobrar)' };
    }
    let _amount = 0; let _charged = false; let _reason = '';

    if (seats > prev) {
      // AMPLIAR: cobrar YA solo los asientos nuevos (parte proporcional hasta la
      // renovación), SIN tocar lo ya pagado ni su descuento. El prorrateo estándar
      // de Stripe (abono+recargo) perdía el cupón inicial. Aquí se emite un cargo
      // ONE-OFF DESACOPLADO de la suscripción (customer, sin subscription=): así se
      // cobra al instante. Con subscription= el ítem quedaba pendiente para la
      // próxima renovación (~1 año) y no se cobraba nada ahora.
      const price = item.price ?? {};
      const plan = item.plan ?? {}; // estructura legada (subs antiguas)
      const custId = typeof sub.customer === 'string' ? sub.customer : sub.customer?.id;
      const nowS = Math.floor(Date.now() / 1000);
      // El periodo actual: primero a nivel de ítem (API nueva), luego de la sub.
      const start = item.current_period_start ?? sub.current_period_start ?? nowS;
      const end = item.current_period_end ?? sub.current_period_end ?? nowS;
      const frac = end > start ? Math.max(0, Math.min(1, (end - nowS) / (end - start))) : 1;
      const added = seats - prev;
      // Importe unitario del asiento (céntimos). unit_amount puede venir null si el
      // precio usa unit_amount_decimal o la estructura legada `plan`; y como último
      // recurso, el precio base según el periodo (2,50€/mes · 30€/año).
      const interval = price.recurring?.interval || plan.interval;
      let unit = price.unit_amount;
      if (unit == null && price.unit_amount_decimal != null) unit = Math.round(Number(price.unit_amount_decimal));
      if (unit == null && plan.amount != null) unit = plan.amount;
      if (unit == null || Number.isNaN(unit)) unit = interval === 'year' ? 3000 : 250;
      const currency = price.currency ?? plan.currency ?? 'eur';
      _amount = Math.round(unit * added * frac);
      _reason = `unit=${unit} added=${added} frac=${frac.toFixed(3)} cust=${!!custId}`;
      if (_amount > 0 && custId) {
        // La factura one-off necesita una tarjeta explícita: el cliente creado por
        // Checkout no tiene invoice_settings.default_payment_method. Se usa la de
        // la suscripción; si no, la del cliente; si no, la primera tarjeta guardada.
        let pmId = typeof sub.default_payment_method === 'string'
          ? sub.default_payment_method : sub.default_payment_method?.id;
        if (!pmId) {
          try {
            const cust = await stripe.customers.retrieve(custId);
            const d = cust?.invoice_settings?.default_payment_method;
            pmId = typeof d === 'string' ? d : d?.id;
          } catch { /* sigue buscando */ }
        }
        if (!pmId) {
          try {
            const pms = await stripe.paymentMethods.list({ customer: custId, type: 'card', limit: 1 });
            pmId = pms.data?.[0]?.id;
          } catch { /* sin tarjetas */ }
        }
        if (!pmId) throw new Error('no hay tarjeta guardada para cobrar el asiento');

        await stripe.invoiceItems.create({
          customer: custId,
          currency,
          amount: _amount,
          description: `TaxiCount: ${added} asiento(s) adicional(es) — prorrateado hasta la renovación`,
        });
        const inv = await stripe.invoices.create({
          customer: custId,
          collection_method: 'charge_automatically',
          auto_advance: false,
          default_payment_method: pmId, // tarjeta con la que cobrar
          pending_invoice_items_behavior: 'include', // incluye el cargo one-off
          // Los asientos nuevos SIEMPRE a precio base: el cupón (attach a la
          // suscripción) es un descuento de RENOVACIÓN, no de ampliación. Así no
          // se gasta ni se aplica por error a esta compra.
          discounts: [],
        });
        const fin = await stripe.invoices.finalizeInvoice(inv.id);
        if (fin.status !== 'paid') {
          try {
            await stripe.invoices.pay(fin.id, { payment_method: pmId });
          } catch (e) {
            try { await stripe.invoices.voidInvoice(fin.id); } catch { /* ya anulada */ }
            throw new Error(`el cobro del asiento no se pudo completar: ${e.message}`);
          }
        }
        _charged = true;
        app.log.info(`[seats] tenant ${tenantId}: cobrado one-off ${_amount} cts (${added} asientos)`);
      } else {
        app.log.warn(`[seats] tenant ${tenantId}: NO se cobra -> ${_reason}`);
      }
      await stripe.subscriptionItems.update(item.id, { quantity: seats, proration_behavior: 'none' });
      app.log.info(`[seats] tenant ${tenantId}: asientos ${prev} -> ${seats}`);
    } else {
      // REDUCIR: el sobrante se acredita en la próxima factura (sin cobro).
      await stripe.subscriptionItems.update(item.id, { quantity: seats, proration_behavior: 'create_prorations' });
      _reason = 'reducción: crédito en la próxima factura';
      app.log.info(`[seats] tenant ${tenantId}: asientos ${prev} -> ${seats} (create_prorations)`);
    }
    return { seats, prev, amount: _amount, charged: _charged, reason: _reason };
  }

  // Aplica el cupo de asientos pagados: refleja la cantidad de Stripe en
  // tenants.drivers_limit y BLOQUEA (active=false) los conductores MÁS NUEVOS
  // que sobren (mantiene los 'seats' más antiguos). Se llama tras los eventos de
  // suscripción (p. ej. al acabar la prueba y pagar N asientos). Best-effort.
  async function enforceSeatLimit(tenantId) {
    if (!stripe || !tenantId) return;
    try {
      const { data: t } = await supabase.from('tenants')
        .select('stripe_subscription_id, subscription_status').eq('id', tenantId).maybeSingle();
      const subId = t?.stripe_subscription_id;
      if (!subId) return;
      if (!['active', 'past_due'].includes(t?.subscription_status)) return;
      const sub = await stripe.subscriptions.retrieve(subId);
      const seats = sub.items?.data?.[0]?.quantity;
      if (seats == null) return;
      await supabase.from('tenants').update({ drivers_limit: seats }).eq('id', tenantId);
      // Bloquear los más nuevos que sobren.
      const { data: actives } = await supabase.from('users')
        .select('id').eq('tenant_id', tenantId).eq('role', 'driver').eq('active', true)
        .order('created_at', { ascending: true });
      const list = actives || [];
      if (list.length > seats) {
        const toBlock = list.slice(seats).map((u) => u.id);
        await supabase.from('users').update({ active: false }).in('id', toBlock);
        app.log.info(`[seats] tenant ${tenantId}: bloqueados ${toBlock.length} conductores (cupo ${seats})`);
      }
    } catch (e) {
      app.log.warn(`[seats] enforce ${tenantId}: ${e.message}`);
    }
  }

  // Ajustar el nº de ASIENTOS PAGADOS (comprar/reducir). El jefe paga por
  // adelantado su cupo de conductores; para añadir por encima de lo pagado,
  // primero sube aquí los asientos (se cobra la parte proporcional YA). Reducir
  // por debajo de los conductores activos bloquea los más nuevos.
  app.post('/api/v1/subscription/seats', async (request, reply) => {
    if (!stripe) return reply.code(500).send({ error: 'Stripe no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (caller.role !== 'owner') return reply.code(403).send({ error: 'Solo un Owner puede cambiar los asientos' });
    const seats = Math.trunc(Number((request.body ?? {}).seats));
    if (!Number.isFinite(seats) || seats < 1) return reply.code(400).send({ error: 'Número de asientos inválido' });
    if (seats > MAX_SEATS) {
      return reply.code(400).send({ code: 'over_max_seats', error: `El máximo por app son ${MAX_SEATS} asientos. Para más, contacta con nosotros.` });
    }
    const { data: t } = await supabase.from('tenants')
      .select('stripe_subscription_id, subscription_status').eq('id', caller.tenant_id).maybeSingle();
    const paid = t?.subscription_status === 'active' || t?.subscription_status === 'past_due';
    if (!t?.stripe_subscription_id || !paid) {
      return reply.code(400).send({ error: 'Durante la prueba no hace falta comprar asientos; puedes añadir conductores libremente.' });
    }
    let diag;
    try {
      diag = await setSeatQuantity(caller.tenant_id, seats);
    } catch (e) {
      return reply.code(502).send({ error: `No se pudo actualizar los asientos: ${e.message}` });
    }
    await supabase.from('tenants').update({ drivers_limit: seats }).eq('id', caller.tenant_id);
    await enforceSeatLimit(caller.tenant_id); // bloquea los más nuevos si se redujo
    return reply.send({ ok: true, seats, prev: diag.prev, amount: diag.amount, charged: diag.charged, reason: diag.reason });
  });

  // Info del asiento (para el aviso de cobro ANTES de comprar): cantidad actual,
  // periodo real (month|year) y precio unitario, leídos de Stripe. Así la UI puede
  // avisar "se cobrará X/conductor de forma proporcional" con el periodo correcto.
  app.get('/api/v1/subscription/seats', async (request, reply) => {
    if (!stripe) return reply.code(500).send({ error: 'Stripe no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    const { data: t } = await supabase.from('tenants')
      .select('stripe_subscription_id, subscription_status').eq('id', caller.tenant_id).maybeSingle();
    const subId = t?.stripe_subscription_id;
    const paid = t?.subscription_status === 'active' || t?.subscription_status === 'past_due';
    if (!subId || !paid) return reply.send({ seats: null, interval: null, unit_amount: null, currency: 'eur' });
    try {
      const sub = await stripe.subscriptions.retrieve(subId, { expand: ['items.data.price'] });
      const item = sub.items?.data?.[0];
      const price = item?.price;
      const qty = item?.quantity ?? null;
      // Auto-sincroniza: los asientos PAGADOS son la cantidad de Stripe. Si la BD
      // (tenants.drivers_limit) se quedó desfasada, se corrige aquí para que tanto
      // la tarjeta como el límite de alta de conductores usen el número real.
      if (qty != null) {
        await supabase.from('tenants').update({ drivers_limit: qty })
          .eq('id', caller.tenant_id).neq('drivers_limit', qty);
      }
      return reply.send({
        seats: qty,
        interval: price?.recurring?.interval ?? null, // 'month' | 'year'
        unit_amount: price?.unit_amount ?? null,       // en céntimos
        currency: price?.currency ?? 'eur',
        cancel_at_period_end: !!sub.cancel_at_period_end,
        current_period_end: sub.current_period_end
          ? new Date(sub.current_period_end * 1000).toISOString() : null,
      });
    } catch (e) {
      return reply.code(502).send({ error: e.message });
    }
  });

  // Cancelar la suscripción a FIN DE PERIODO (no corta el servicio ya pagado):
  // el cliente sigue activo hasta current_period_end y luego no se renueva.
  // `resume:true` deshace la cancelación programada. Solo Owner.
  app.post('/api/v1/subscription/cancel', async (request, reply) => {
    if (!stripe) return reply.code(500).send({ error: 'Stripe no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (caller.role !== 'owner') return reply.code(403).send({ error: 'Solo un Owner puede cancelar la suscripción' });
    const resume = (request.body ?? {}).resume === true;
    const { data: t } = await supabase.from('tenants')
      .select('stripe_subscription_id').eq('id', caller.tenant_id).maybeSingle();
    const subId = t?.stripe_subscription_id;
    if (!subId) return reply.code(400).send({ error: 'No hay suscripción activa' });
    try {
      const sub = await stripe.subscriptions.update(subId, { cancel_at_period_end: !resume });
      return reply.send({
        ok: true,
        cancel_at_period_end: !!sub.cancel_at_period_end,
        current_period_end: sub.current_period_end
          ? new Date(sub.current_period_end * 1000).toISOString() : null,
      });
    } catch (e) {
      return reply.code(502).send({ error: `No se pudo cambiar la cancelación: ${e.message}` });
    }
  });

  // Aplicar un CUPÓN a una suscripción YA activa: el descuento se aplica a la
  // PRÓXIMA factura (la renovación) — no hace falta "adelantar" ningún pago, la
  // renovación se cobra sola con el descuento. Un uso por empresa (igual que en
  // el Checkout): se marca coupon_redeemed_code. Solo Owner.
  app.post('/api/v1/subscription/apply-coupon', async (request, reply) => {
    if (!stripe) return reply.code(500).send({ error: 'Stripe no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (caller.role !== 'owner') return reply.code(403).send({ error: 'Solo un Owner puede aplicar un cupón' });
    const code = String((request.body ?? {}).code ?? '').trim().toUpperCase();
    if (!code) return reply.code(400).send({ error: 'Código de cupón obligatorio' });

    const { data: t } = await supabase.from('tenants')
      .select('stripe_subscription_id, subscription_status, coupon_redeemed_code')
      .eq('id', caller.tenant_id).maybeSingle();
    const subId = t?.stripe_subscription_id;
    const paid = t?.subscription_status === 'active' || t?.subscription_status === 'past_due';
    if (!subId || !paid) {
      return reply.code(400).send({ error: 'Necesitas una suscripción activa; si aún no tienes, introduce el cupón al suscribirte.' });
    }
    if (t?.coupon_redeemed_code && t.coupon_redeemed_code === code) {
      return reply.code(409).send({ error: 'Ya has usado este cupón.' });
    }
    try {
      // UN solo cupón por renovación: si la suscripción ya tiene un descuento
      // pendiente (aplicado y aún no consumido por la renovación), se rechaza.
      // Ni se acumulan ni se puede cambiar por otro mejor. Tras la renovación
      // (que consume el descuento 'once'), el hueco queda libre para el año
      // siguiente.
      const sub = await stripe.subscriptions.retrieve(subId);
      const hasPending = (Array.isArray(sub.discounts) && sub.discounts.length > 0) || !!sub.discount;
      if (hasPending) {
        return reply.code(409).send({
          code: 'coupon_pending',
          error: 'Ya tienes un cupón aplicado a tu próxima renovación. Solo se puede usar un cupón por renovación.',
        });
      }
      const list = await stripe.promotionCodes.list({ code, active: true, limit: 1 });
      const promo = list.data?.[0];
      if (!promo || !promo.coupon?.valid) {
        return reply.code(404).send({ code: 'bad_coupon', error: 'Cupón no válido o caducado' });
      }
      await stripe.subscriptions.update(subId, { discounts: [{ promotion_code: promo.id }] });
      // Un uso por empresa: marcarlo canjeado (también oculta el aviso en la app).
      await supabase.from('tenants')
        .update({ coupon_redeemed_code: promo.code }).eq('id', caller.tenant_id);
      app.log.info(`[coupon] tenant ${caller.tenant_id}: cupón ${promo.code} aplicado a la suscripción`);
      return reply.send({ ok: true, code: promo.code, pct: Math.round(promo.coupon.percent_off || 0) });
    } catch (e) {
      return reply.code(502).send({ error: `No se pudo aplicar el cupón: ${e.message}` });
    }
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
      .select('stripe_customer_id, coupon_redeemed_code')
      .eq('id', caller.tenant_id)
      .single();

    const metadata = {
      tenant_id: caller.tenant_id,
      plan_id: plan.plan_id,
      drivers_limit: plan.drivers_limit === null ? 'null' : String(plan.drivers_limit),
    };

    // Cantidad = nº de conductores (asientos). Máximo MAX_SEATS: por encima, plan
    // a medida (que contacten). Modelo lineal por asiento, sin tramo plano.
    const quantity = await seatCount(caller.tenant_id);
    if (quantity > MAX_SEATS) {
      return reply.code(400).send({
        error: `El máximo por app son ${MAX_SEATS} conductores. Para más, contacta con nosotros.`,
        code: 'over_max_seats',
      });
    }

    // El plan ANUAL admite cupones (bienvenida 50% 1 vez / fidelidad 20%); el
    // cliente los introduce en el checkout. El MENSUAL es precio fijo, sin cupones.
    const isYearly = !!STRIPE_PRICE_SEAT_YEARLY && priceId === STRIPE_PRICE_SEAT_YEARLY;
    // Blindaje del cupón de bienvenida: si este tenant YA canjeó el cupón activo,
    // NO se ofrece el campo de código promocional (si no, podría re-escribirlo y
    // volver a canjearlo). Es por CÓDIGO: si el cupón activo es otro distinto, sí
    // se ofrece. Un cliente que nunca lo canjeó lo sigue teniendo.
    const activeCoupon = await readActiveCoupon();
    const alreadyRedeemed = !!(activeCoupon && tenant?.coupon_redeemed_code
      && tenant.coupon_redeemed_code === activeCoupon.code);

    try {
      const session = await stripe.checkout.sessions.create({
        mode: 'subscription',
        // adjustable_quantity: el cliente puede ajustar el nº de conductores
        // (asientos) en el propio Checkout, entre 1 y MAX_SEATS.
        line_items: [{
          price: priceId, quantity,
          adjustable_quantity: { enabled: true, minimum: 1, maximum: MAX_SEATS },
        }],
        success_url: STRIPE_SUCCESS_URL,
        cancel_url: STRIPE_CANCEL_URL,
        ...(tenant?.stripe_customer_id ? { customer: tenant.stripe_customer_id } : {}),
        ...(isYearly && !alreadyRedeemed ? { allow_promotion_codes: true } : {}),
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

  // Cupón activo para el owner: devuelve {code, pct, show}. `show` = true si hay
  // un cupón activo y este tenant NO lo ha canjeado todavía (para el aviso con
  // "copiar código" al entrar en Suscripción).
  //
  // FUENTE DE VERDAD = STRIPE. Se lee el promotion code activo real en Stripe, de
  // modo que lo que se cree/modifique/borre en Stripe se refleja en la app (y al
  // revés, porque crear/desactivar desde el panel también toca Stripe). La config
  // local solo aporta el "puntero" (promo_id que anunciamos) y la programación
  // (starts_at). Si no hay puntero válido, se AUTODESCUBRE el promo activo en
  // Stripe (preferimos el restringido al producto anual y con mayor % de dto.).
  let _annualProductId; // cache del producto del precio anual
  async function annualProductId() {
    if (_annualProductId !== undefined) return _annualProductId;
    _annualProductId = null;
    if (stripe && STRIPE_PRICE_SEAT_YEARLY) {
      try {
        const price = await stripe.prices.retrieve(STRIPE_PRICE_SEAT_YEARLY);
        _annualProductId = typeof price.product === 'string' ? price.product : (price.product?.id ?? null);
      } catch { /* sin producto */ }
    }
    return _annualProductId;
  }

  async function readActiveCoupon() {
    if (!stripe) return null;
    try {
      const cfg = await readCouponConfigRaw();
      const now = Date.now();
      // Programación: si aún no ha llegado su día, no se muestra.
      if (cfg?.starts_at && new Date(cfg.starts_at).getTime() > now) return null;

      let promo = null;
      if (cfg?.promo_id) {
        try { promo = await stripe.promotionCodes.retrieve(cfg.promo_id); } catch { promo = null; }
      }
      // Puntero ausente/obsoleto (borrado o desactivado en Stripe) -> autodescubrir.
      if (!promo || !promo.active) {
        const prod = await annualProductId();
        const list = await stripe.promotionCodes.list({ active: true, limit: 100 });
        const cand = list.data.filter((p) => p.active && p.coupon && p.coupon.valid && p.coupon.percent_off);
        // Preferir los restringidos al producto anual; luego mayor % de descuento.
        cand.sort((a, b) => {
          const ap = prod && (a.coupon.applies_to?.products || []).includes(prod) ? 1 : 0;
          const bp = prod && (b.coupon.applies_to?.products || []).includes(prod) ? 1 : 0;
          if (ap !== bp) return bp - ap;
          return (b.coupon.percent_off || 0) - (a.coupon.percent_off || 0);
        });
        promo = cand[0] || null;
      }
      if (!promo || !promo.active || !promo.coupon?.valid) return null;
      if (promo.expires_at && promo.expires_at * 1000 < now) return null;
      return {
        code: promo.code,
        pct: Math.round(promo.coupon.percent_off || 0),
        coupon_id: promo.coupon.id,
        promo_id: promo.id,
        expires_at: promo.expires_at ? new Date(promo.expires_at * 1000).toISOString() : null,
        starts_at: cfg?.starts_at ?? null,
        max_redemptions: promo.max_redemptions ?? null,
      };
    } catch { return null; }
  }

  // Config crudo del cupón (incluye ids de Stripe aunque esté programado/caducado).
  async function readCouponConfigRaw() {
    try {
      const { data } = await supabase.from('system_config')
        .select('value').eq('key', 'active_coupon').maybeSingle();
      return data?.value ? JSON.parse(data.value) : null;
    } catch { return null; }
  }

  app.get('/api/v1/tenant/active-coupon', async (request, reply) => {
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    const coupon = await readActiveCoupon();
    if (!coupon) return reply.send({ show: false });
    const { data: t } = await supabase.from('tenants')
      .select('coupon_redeemed_code').eq('id', caller.tenant_id).maybeSingle();
    const redeemed = t?.coupon_redeemed_code || '';
    return reply.send({ code: coupon.code, pct: coupon.pct, show: redeemed !== coupon.code });
  });

  // Admin: cupón activo actual (para la pantalla de Facturación).
  app.get('/api/v1/admin/active-coupon', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const coupon = await readActiveCoupon();
    // `config` incluye TODOS los parámetros guardados (duration, meses, máx,
    // fechas…) para poder pre-rellenar el diálogo de edición.
    const config = await readCouponConfigRaw();
    return reply.send({ coupon, config });
  });

  // Admin: DESACTIVA el cupón activo. Además de limpiar la config, desactiva el
  // promotion code en Stripe (active:false) para que NADIE lo pueda usar ya.
  app.post('/api/v1/admin/active-coupon', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    // Resuelve el promo REAL (puntero de config o autodescubierto en Stripe) para
    // desactivarlo, no solo lo que hubiera en la config local.
    const raw = await readCouponConfigRaw();
    const active = await readActiveCoupon();
    const promoId = raw?.promo_id || active?.promo_id;
    if (stripe && promoId) {
      try { await stripe.promotionCodes.update(promoId, { active: false }); }
      catch (e) { request.log.warn(`[coupon] no se pudo desactivar en Stripe: ${e.message}`); }
    }
    await supabase.from('system_config')
      .upsert({ key: 'active_coupon', value: JSON.stringify({ code: '' }) }, { onConflict: 'key' });
    await logAdminAction(request, g.caller?.id ?? null, 'active_coupon_set', 'system_config', null, { code: '' });
    return reply.send({ ok: true });
  });

  // Admin: CREA el cupón en Stripe (coupon + promotion code) y lo deja activo.
  // Opciones: pct, duration ('once'|'forever'|'repeating' + duration_in_months),
  // max_redemptions (total), starts_at (programación), expires_at (caducidad).
  // El coupon se RESTRINGE al producto del precio ANUAL (applies_to) para que solo
  // valga en el plan anual. Guarda los ids de Stripe para poder desactivarlo luego.
  app.post('/api/v1/admin/coupons', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    if (!stripe) return reply.code(500).send({ error: 'Stripe no configurado' });
    const body = request.body ?? {};
    const code = String(body.code || '').trim().toUpperCase();
    const pct = Number(body.pct);
    const duration = ['once', 'forever', 'repeating'].includes(body.duration) ? body.duration : 'once';
    const months = duration === 'repeating' ? Math.max(1, Number(body.duration_in_months) || 1) : null;
    const maxRedemptions = body.max_redemptions ? Number(body.max_redemptions) : null;
    const startsAt = body.starts_at || null; // ISO
    const expiresAt = body.expires_at || null; // ISO
    if (!code || !Number.isFinite(pct) || pct <= 0 || pct > 100) {
      return reply.code(400).send({ error: 'Código y porcentaje (1-100) obligatorios' });
    }
    const now = Date.now();
    const startFuture = startsAt && new Date(startsAt).getTime() > now;
    try {
      // Producto del precio anual, para restringir el cupón a ese producto.
      let productId = null;
      if (STRIPE_PRICE_SEAT_YEARLY) {
        try {
          const price = await stripe.prices.retrieve(STRIPE_PRICE_SEAT_YEARLY);
          productId = typeof price.product === 'string' ? price.product : price.product?.id;
        } catch (e) { request.log.warn(`[coupon] no se pudo leer el precio anual: ${e.message}`); }
      }
      const coupon = await stripe.coupons.create({
        percent_off: pct, duration, name: code,
        ...(months ? { duration_in_months: months } : {}),
        ...(productId ? { applies_to: { products: [productId] } } : {}),
        ...(expiresAt ? { redeem_by: Math.floor(new Date(expiresAt).getTime() / 1000) } : {}),
      });
      const promo = await stripe.promotionCodes.create({
        coupon: coupon.id, code,
        // Si empieza en el futuro, se crea INACTIVO; el cron lo activa el día fijado.
        active: !startFuture,
        ...(maxRedemptions ? { max_redemptions: maxRedemptions } : {}),
        ...(expiresAt ? { expires_at: Math.floor(new Date(expiresAt).getTime() / 1000) } : {}),
      });
      // Solo hay UN cupón vigente: al lanzar uno nuevo se RETIRA el anterior
      // (nadie más puede canjearlo). Los descuentos ya aplicados a suscripciones
      // se conservan (la caducidad/desactivación solo afecta a canjes nuevos).
      // Si el nuevo está PROGRAMADO, el anterior sigue vivo hasta que el nuevo
      // se active (el vigía lo retira entonces, vía prev_promo_id).
      const prevRaw = await readCouponConfigRaw();
      let prevPromoId = null;
      if (prevRaw?.promo_id && prevRaw.promo_id !== promo.id) {
        if (startFuture) {
          prevPromoId = prevRaw.promo_id;
        } else {
          try { await stripe.promotionCodes.update(prevRaw.promo_id, { active: false }); }
          catch (e) { request.log.warn(`[coupon] no se pudo retirar el anterior: ${e.message}`); }
        }
      }
      const value = JSON.stringify({
        code, pct, duration, duration_in_months: months, max_redemptions: maxRedemptions,
        starts_at: startsAt, expires_at: expiresAt, coupon_id: coupon.id, promo_id: promo.id,
        ...(prevPromoId ? { prev_promo_id: prevPromoId } : {}),
      });
      await supabase.from('system_config').upsert({ key: 'active_coupon', value }, { onConflict: 'key' });
      await logAdminAction(request, g.caller?.id ?? null, 'coupon_create', 'system_config', null,
        { code, pct, duration, promo_id: promo.id, product: productId });
      return reply.send({ ok: true, code, pct, promotion_code_id: promo.id, applies_to_product: productId });
    } catch (e) {
      request.log.error(e);
      return reply.code(502).send({ error: `Stripe: ${e.message}` });
    }
  });

  // Sincroniza el estado del promo code en Stripe con la programación (starts_at/
  // expires_at): lo activa cuando llega su día y lo desactiva al caducar. Lo llama
  // el vigía de semáforos (cada 15 min). Best-effort.
  async function syncScheduledCoupon() {
    if (!stripe) return;
    const raw = await readCouponConfigRaw();
    if (!raw?.promo_id) return;
    const now = Date.now();
    const started = !raw.starts_at || new Date(raw.starts_at).getTime() <= now;
    const expired = raw.expires_at && new Date(raw.expires_at).getTime() < now;
    const shouldBeActive = started && !expired;
    try {
      const promo = await stripe.promotionCodes.retrieve(raw.promo_id);
      if (promo.active !== shouldBeActive) {
        await stripe.promotionCodes.update(raw.promo_id, { active: shouldBeActive });
      }
      // Al ACTIVARSE un cupón programado, retirar el anterior (prev_promo_id):
      // el cupón vigente es único. Una sola vez (se limpia el puntero).
      if (shouldBeActive && raw.prev_promo_id) {
        try { await stripe.promotionCodes.update(raw.prev_promo_id, { active: false }); }
        catch (e) { app.log.warn(`[coupon-sync] retirar anterior: ${e.message}`); }
        const { prev_promo_id: _prev, ...rest } = raw;
        await supabase.from('system_config')
          .upsert({ key: 'active_coupon', value: JSON.stringify(rest) }, { onConflict: 'key' });
      }
    } catch (e) { app.log.warn(`[coupon-sync] ${e.message}`); }
  }

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
            // Un logro SOSPECHOSO entra como 'pending' (lo revisa el admin): así
            // NO cuenta como completado ni cobra recompensa hasta que se acepta.
            // Los logros limpios siguen auto-aprobados ('rewarded'), sin fricción.
            const { error: insErr } = await supabase.from('challenge_claims').insert({
              tenant_id: caller.tenant_id, user_id: r.user_id, challenge: type,
              level: st.level, baseline: st.baseline, target,
              metric_value: metric, active_days: activeDays, suspicious,
              status: suspicious ? 'pending' : 'rewarded',
              reviewed_at: suspicious ? null : new Date().toISOString(),
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
    for (const c of claims ?? []) {
      if (c.status === 'rewarded') {
        // Solo cuenta como "conductor con reto" quien tiene un logro COMPLETADO
        // (rewarded); los pendientes/rechazados no cuentan (si no, un fraude
        // rechazado seguiría inflando el %).
        driversWithClaim.add(c.user_id);
        totalCompleted += 1;
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
    const driversWithChallenge = totalDrivers
      ? +((driversWithClaim.size / totalDrivers) * 100).toFixed(1) : 0;
    // Tasa de compleción = completados / intentos decididos (completados + pendientes
    // + rechazados). Ratio, no volumen (estándar de analítica de engagement).
    const attempts = totalCompleted + pendingApprovals + rejected;
    const completionRate = attempts > 0
      ? +((totalCompleted / attempts) * 100).toFixed(1) : 0;
    // Tasa de fraude = rechazados / (completados + rechazados).
    const fraudRate = (totalCompleted + rejected) > 0
      ? +((rejected / (totalCompleted + rejected)) * 100).toFixed(1) : 0;

    // COSTE real del programa de retos = suma de los CRÉDITOS Stripe concedidos
    // (cada reto completado = 1 asiento·mes a la tarifa efectiva del cliente). Y
    // qué % del valor bruto (cobrado + regalado) supone. Conecta con Facturación.
    const { data: extRows } = await supabase.from('subscription_extensions')
      .select('credit_cents').eq('extension_type', 'challenge').limit(20000);
    const rewardCount = (extRows ?? []).length;
    const rewardCostEur = +((extRows ?? [])
      .reduce((s, r) => s + (r.credit_cents ?? 0), 0) / 100).toFixed(2);
    const rev = await readGlobalRevenue();
    const cashTotal = ((rev?.paid ?? 0) - (rev?.refunded ?? 0)) / 100;
    const rewardPct = (cashTotal + rewardCostEur) > 0
      ? +((rewardCostEur / (cashTotal + rewardCostEur)) * 100).toFixed(1) : 0;

    // Evolución de km RECORRIDOS por día (global, últimos 30 días): muestra cómo
    // AVANZAN los conductores hacia los retos, no solo cuándo los completan.
    // Best-effort: si la RPC no está (migración 067 sin aplicar) devuelve [].
    let kmDaily = [];
    try {
      const { data: km } = await supabase.rpc('challenge_km_daily', { p_days: 30 });
      kmDaily = (km ?? []).map((r) => ({ date: r.day, km: Math.round(Number(r.km) || 0) }));
    } catch { /* RPC ausente: sin serie de km */ }

    return reply.send({
      total_completed: totalCompleted,
      drivers_with_challenge: driversWithChallenge, // %
      completion_rate: completionRate, // % completados / intentos
      reward_count: rewardCount, // nº de recompensas concedidas
      reward_cost_eur: rewardCostEur, // € regalados en recompensas
      reward_pct: rewardPct, // % del valor bruto que regalamos
      pending_approvals: pendingApprovals,
      rejected,
      fraud_rate: fraudRate, // %
      completed_this_month: completedThisMonth,
      daily: Object.entries(daily).map(([date, count]) => ({ date, count })),
      km_daily: kmDaily,
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

  // Admin: km de un conductor para CORREGIR un valor mal introducido. Devuelve
  // AMBOS orígenes que alimentan los retos y el km/día: (1) lecturas de jornada
  // (odometer_readings) y (2) el odómetro apuntado en cada carrera (transactions
  // .odometer_km). Cada uno se corrige/elimina con su propio endpoint. Se unifican
  // en una lista `entries` (source: 'reading' | 'transaction'), más recientes primero.
  app.get('/api/v1/admin/drivers/:userId/odometer', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const limit = Math.min(Number(request.query?.limit) || 60, 300);
    const [rd, tx] = await Promise.all([
      supabase.from('odometer_readings')
        .select('id, vehicle_id, reading_km, taken_at, vehicles:vehicle_id(license_plate, model)')
        .eq('user_id', request.params.userId)
        .order('taken_at', { ascending: false }).limit(limit),
      supabase.from('transactions')
        .select('id, vehicle_id, odometer_km, created_at, vehicles:vehicle_id(license_plate, model)')
        .eq('user_id', request.params.userId).not('odometer_km', 'is', null)
        .order('created_at', { ascending: false }).limit(limit),
    ]);
    if (rd.error) return reply.code(500).send({ error: rd.error.message });
    // Km INICIAL de cada vehículo que usa el conductor (source 'vehicle'): es el
    // punto de partida del odómetro (al dar de alta el coche). Aparte de las
    // lecturas de jornada y del odómetro de cada carrera.
    const vehIds = [...new Set([
      ...(rd.data ?? []).map((r) => r.vehicle_id),
      ...(tx.data ?? []).map((t) => t.vehicle_id),
    ].filter(Boolean))];
    let vehicles = [];
    if (vehIds.length) {
      const { data: vs } = await supabase.from('vehicles')
        .select('id, license_plate, initial_odometer, created_at').in('id', vehIds);
      vehicles = vs ?? [];
    }
    const entries = [
      ...vehicles.map((v) => ({
        source: 'vehicle', id: v.id, km: v.initial_odometer ?? 0, at: v.created_at,
        plate: v.license_plate ?? null,
      })),
      ...(rd.data ?? []).map((r) => ({
        source: 'reading', id: r.id, km: r.reading_km, at: r.taken_at,
        plate: (r.vehicles || {}).license_plate ?? null,
      })),
      ...(tx.data ?? []).map((t) => ({
        source: 'transaction', id: t.id, km: t.odometer_km, at: t.created_at,
        plate: (t.vehicles || {}).license_plate ?? null,
      })),
    ].sort((a, b) => new Date(b.at) - new Date(a.at));
    // `readings` se mantiene por compatibilidad con clientes antiguos.
    return reply.send({ entries, readings: rd.data ?? [] });
  });

  // Admin: corrige el km de una lectura (reading_km). Queda auditado con el valor
  // anterior y el nuevo. Los retos se recalculan solos en la próxima lectura (leen
  // el odómetro en vivo); no hay rollups de km que refrescar.
  app.patch('/api/v1/admin/odometer/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const km = Number((request.body ?? {}).reading_km);
    if (!Number.isFinite(km) || km < 0 || km > 100000000) {
      return reply.code(400).send({ error: 'km no válido' });
    }
    const { data: row } = await supabase.from('odometer_readings')
      .select('id, tenant_id, user_id, reading_km').eq('id', request.params.id).maybeSingle();
    if (!row) return reply.code(404).send({ error: 'Lectura no encontrada' });
    const newKm = Math.round(km);
    await supabase.from('odometer_readings')
      .update({ reading_km: newKm }).eq('id', row.id);
    await logAdminAction(request, g.caller?.id ?? null, 'odometer_correct', 'odometer_readings', row.id,
      { user_id: row.user_id, from: row.reading_km, to: newKm });
    return reply.send({ ok: true, reading_km: newKm });
  });

  // Admin: elimina una lectura errónea (p. ej. un km de inicio duplicado o falso).
  app.delete('/api/v1/admin/odometer/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { data: row } = await supabase.from('odometer_readings')
      .select('id, user_id, reading_km, taken_at').eq('id', request.params.id).maybeSingle();
    if (!row) return reply.code(404).send({ error: 'Lectura no encontrada' });
    await supabase.from('odometer_readings').delete().eq('id', row.id);
    await logAdminAction(request, g.caller?.id ?? null, 'odometer_delete', 'odometer_readings', row.id,
      { user_id: row.user_id, reading_km: row.reading_km, taken_at: row.taken_at });
    return reply.send({ ok: true });
  });

  // Admin: corrige (o borra, con null) el odómetro apuntado en una CARRERA
  // (transactions.odometer_km) — la otra fuente del km de los retos. Solo toca ese
  // campo; el importe/fecha de la carrera no se alteran. Queda auditado.
  app.patch('/api/v1/admin/transactions/:id/odometer', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const body = request.body ?? {};
    let newKm = null;
    if (body.odometer_km !== null && body.odometer_km !== undefined && body.odometer_km !== '') {
      const km = Number(body.odometer_km);
      if (!Number.isFinite(km) || km < 0 || km > 100000000) {
        return reply.code(400).send({ error: 'km no válido' });
      }
      newKm = Math.round(km);
    }
    const { data: row } = await supabase.from('transactions')
      .select('id, user_id, odometer_km').eq('id', request.params.id).maybeSingle();
    if (!row) return reply.code(404).send({ error: 'Carrera no encontrada' });
    await supabase.from('transactions')
      .update({ odometer_km: newKm }).eq('id', row.id);
    await logAdminAction(request, g.caller?.id ?? null, 'odometer_correct', 'transactions', row.id,
      { user_id: row.user_id, from: row.odometer_km, to: newKm });
    return reply.send({ ok: true, odometer_km: newKm });
  });

  // Admin: corrige el km INICIAL de un vehículo (initial_odometer, y registered_km
  // por compat). Es el punto de partida del odómetro para los km de retos. Auditado.
  app.patch('/api/v1/admin/vehicles/:id/odometer', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const km = Number((request.body ?? {}).initial_odometer);
    if (!Number.isFinite(km) || km < 0 || km > 100000000) {
      return reply.code(400).send({ error: 'km no válido' });
    }
    const { data: row } = await supabase.from('vehicles')
      .select('id, initial_odometer').eq('id', request.params.id).maybeSingle();
    if (!row) return reply.code(404).send({ error: 'Vehículo no encontrado' });
    const newKm = Math.round(km);
    await supabase.from('vehicles')
      .update({ initial_odometer: newKm, registered_km: newKm }).eq('id', row.id);
    await logAdminAction(request, g.caller?.id ?? null, 'odometer_correct', 'vehicles', row.id,
      { from: row.initial_odometer, to: newKm });
    return reply.send({ ok: true, initial_odometer: newKm });
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
    if (qp.from) q = q.gte('created_at', qp.from);
    if (qp.to) q = q.lte('created_at', qp.to);
    const { data, count, error } = await q.range(offset, offset + limit - 1);
    if (error) return reply.code(500).send({ error: error.message });
    return reply.send({ logs: data ?? [], total: count ?? (data ?? []).length, limit, offset });
  });

  // Estado (log) de TODOS los semáforos de la plataforma, para el apartado de
  // Auditoría del panel de admin. Lee system_config (cron_last_* y svc_*) y
  // devuelve, por cada semáforo, su último resultado y cuándo fue. Estados:
  //   ok     verde (cron reciente <48h, o servicio cuya última llamada fue OK)
  //   stale  rojo  (cron sin ejecutarse hace >=48h)
  //   error  rojo  (servicio cuya última llamada falló)
  //   never  gris  (aún sin datos)
  //   live   verde (API: si respondemos, está viva)
  // Calcula el estado de todos los semáforos (compartido por el endpoint de
  // admin y el del vigía externo).
  async function computeSemaphores() {
    const cfg = {};
    for (const pat of ['cron_last_%', 'svc_%']) {
      const { data: rows } = await supabase.from('system_config')
        .select('key, value').like('key', pat);
      for (const r of rows ?? []) cfg[r.key] = r.value;
    }
    const now = Date.now();
    const FRESH_MS = 48 * 60 * 60 * 1000;

    const cronSema = (key) => {
      const at = cfg[`cron_last_${key}`] || null;
      if (!at) return { key, kind: 'cron', ok: false, at: null, status: 'never' };
      const stale = now - new Date(at).getTime() > FRESH_MS;
      return { key, kind: 'cron', ok: !stale, at, status: stale ? 'stale' : 'ok' };
    };
    const svcSema = (key) => {
      const raw = cfg[`svc_${key}`];
      if (!raw) return { key, kind: 'service', ok: true, at: null, status: 'never' };
      const [st, at] = String(raw).split('|');
      const isErr = st === 'err';
      // Un error ANTIGUO (>24 h) deja de alertar: un fallo puntual (p. ej. un
      // evento de prueba de Stripe con otro secreto, o una llamada suelta a
      // Whisper) no debe dejar el semáforo en rojo para siempre. La próxima
      // llamada correcta lo pone verde; mientras, no gritamos por algo viejo.
      const recent = at && (now - new Date(at).getTime() < 24 * 60 * 60 * 1000);
      const err = isErr && recent;
      return { key, kind: 'service', ok: !err, at: at || null,
        status: err ? 'error' : (isErr ? 'idle' : 'ok') };
    };

    // La purga de retención NO es un cron periódico (se ejecuta a lo sumo una vez
    // al año); mostramos su última ejecución sin marcarla en rojo por antigüedad.
    const purgeAt = cfg['cron_last_purge_retention'] || null;
    const purgeSema = { key: 'purge_retention', kind: 'cron_rare', ok: true,
      at: purgeAt, status: purgeAt ? 'ok' : 'never' };

    // Push: si FCM NO está configurado (sin service account), el semáforo es
    // "off" (gris, sin alerta): apagado a propósito no es una avería. Un error
    // antiguo registrado en svc_push tampoco debe alertar en ese caso.
    const pushSema = pushEnabled()
      ? svcSema('push')
      : { key: 'push', kind: 'service', ok: true, at: null, status: 'off' };

    // Bandeja de webhooks (Mes 2, M2-6/M2-8): eventos de Stripe sin aplicar.
    //  - 'error'+'dead' = rotos (cobro/cancelación sin reflejar) → rojo;
    //  - 'received' atascados (>10 min) = backlog: el drenaje async no avanza → rojo.
    // Si la tabla aún no existe, "off".
    let webhookSema = { key: 'webhook_errors', kind: 'count', ok: true, at: null, status: 'off' };
    try {
      const stuckCutoff = new Date(now - 10 * 60 * 1000).toISOString();
      const [brokenRes, stuckRes] = await Promise.all([
        supabase.from('webhook_events').select('event_id', { count: 'exact', head: true })
          .in('status', ['error', 'dead']),
        supabase.from('webhook_events').select('event_id', { count: 'exact', head: true })
          .eq('status', 'received').lt('received_at', stuckCutoff),
      ]);
      const broken = brokenRes.count ?? 0;
      const stuck = stuckRes.count ?? 0;
      const n = broken + stuck;
      webhookSema = { key: 'webhook_errors', kind: 'count', ok: n === 0,
        at: new Date().toISOString(), status: n === 0 ? 'ok' : 'error',
        count: n, broken, stuck };
    } catch { /* tabla webhook_events puede no existir aún en prod */ }

    // Groq: % restante en vivo por modelo (svc_groq_rl:*). El semáforo toma el
    // modelo más ajustado; < 20% restante -> rojo.
    let groqSema = { key: 'groq', kind: 'usage', ok: true, at: null, status: 'off' };
    try {
      let minRem = null; let atMin = null;
      for (const k of Object.keys(cfg)) {
        if (!k.startsWith('svc_groq_rl')) continue;
        let s; try { s = JSON.parse(cfg[k]); } catch { continue; }
        const pcts = [];
        if (s.lim_req > 0 && s.rem_req != null) pcts.push(s.rem_req / s.lim_req);
        if (s.lim_tok > 0 && s.rem_tok != null) pcts.push(s.rem_tok / s.lim_tok);
        if (!pcts.length) continue;
        const rem = Math.round(Math.min(...pcts) * 100);
        if (minRem == null || rem < minRem) { minRem = rem; atMin = s.at; }
      }
      if (minRem != null) {
        groqSema = { key: 'groq', kind: 'usage', ok: minRem >= 20, at: atMin,
          status: minRem >= 20 ? 'ok' : 'error', remaining_pct: minRem };
      }
    } catch { /* svc_groq_rl* ausente o no parseable */ }

    // Recursos de Supabase (svc_supabase_res): CPU/RAM/disco > 80% -> rojo.
    let supaResSema = { key: 'supabase_res', kind: 'usage', ok: true, at: null, status: 'off' };
    try {
      const raw = cfg['svc_supabase_res'];
      if (raw) {
        const s = JSON.parse(raw);
        const vals = [s.ram_pct, s.disk_pct, s.cpu_pct].filter((x) => typeof x === 'number');
        if (vals.length) {
          const max = Math.max(...vals);
          supaResSema = { key: 'supabase_res', kind: 'usage', ok: max < 80, at: s.at,
            status: max < 80 ? 'ok' : 'error',
            max_pct: max, ram_pct: s.ram_pct, disk_pct: s.disk_pct, cpu_pct: s.cpu_pct };
        }
      }
    } catch { /* svc_supabase_res ausente */ }

    const db = await probeDb();
    return [
      { key: 'api', kind: 'live', ok: true, at: new Date().toISOString(), status: 'live' },
      { key: 'database', kind: 'db', ok: db.ok, at: db.at, status: db.status, latency_ms: db.latency_ms },
      cronSema('challenge_credits'),
      cronSema('referral_validations'),
      cronSema('backup'),
      purgeSema,
      svcSema('stripe'),
      svcSema('whisper'),
      svcSema('openai'),
      groqSema,
      pushSema,
      webhookSema,
      supaResSema,
    ];
  }

  app.get('/api/v1/admin/semaphores', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    return reply.send({ semaphores: await computeSemaphores() });
  });

  // Monitor de uso: Groq (rate-limit en vivo) + recursos de Supabase (CPU/RAM/
  // disco + tamaño BD y conexiones). Refresca el scrape en cada consulta.
  app.get('/api/v1/admin/metrics', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const [groq, supa] = await Promise.all([groqUsage(), supabaseMetrics()]);
    return reply.send({ groq, supabase: supa });
  });

  // Vigía externo (T11): igual que el anterior pero accesible con x-cron-secret
  // (va bajo /admin/cron/ para la excepción del preHandler). Lo consulta el
  // workflow "Vigía de semáforos" cada 15 min; si algo está stale/error, el
  // workflow FALLA y GitHub avisa por email. Solo estado de plataforma, sin
  // datos de clientes.
  app.get('/api/v1/admin/cron/semaphores', async (request, reply) => {
    const g = await cronOrAdmin(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    // Refresca la foto de recursos de Supabase (best-effort) para que el semáforo
    // supabase_res del vigía no quede obsoleto si nadie abre el panel.
    await supabaseMetrics().catch(() => {});
    await syncScheduledCoupon().catch(() => {});
    const semaphores = await computeSemaphores();
    // Avisos de LÍMITE al admin (push): Groq bajo o recursos de Supabase altos.
    await alertLimit('groq', semaphores, '⚠ Groq cerca del límite',
      (s) => `Queda ${s.remaining_pct ?? '?'}% de la API de Groq disponible.`);
    await alertLimit('supabase_res', semaphores, '⚠ Recursos de Supabase altos',
      (s) => `CPU/RAM/disco al ${s.max_pct ?? '?'}% (umbral 80%).`);
    // "never" no alerta: es un semáforo aún sin datos (p. ej. recién desplegado),
    // no una avería. stale/error sí.
    const red = semaphores.filter((s) => s.status === 'stale' || s.status === 'error');
    return reply.send({ ok: red.length === 0, red: red.map((s) => s.key), semaphores });
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
    const reason = String((request.body ?? {}).reason ?? '').trim().slice(0, 300);
    if (action !== 'reward' && action !== 'reject') {
      return reply.code(400).send({ error: 'Acción no válida' });
    }
    const { data: claim, error: cErr } = await supabase
      .from('challenge_claims').select('id, tenant_id, status, reward_redeemed_at')
      .eq('id', request.params.id).maybeSingle();
    if (cErr || !claim) return reply.code(404).send({ error: 'Reto no encontrado' });

    if (action === 'reject') {
      // Si el logro YA se había premiado (crédito Stripe aplicado por el cron), se
      // revierte con clawback (b): se retira el crédito NO consumido y se borra la
      // recompensa, para que el logro rechazado DESAPAREZCA de "completados" y del
      // crédito acumulado. Si el crédito ya se gastó, se asume (no se cobra de más).
      let clawedCents = 0;
      if (claim.reward_redeemed_at) {
        const { data: exts } = await supabase.from('subscription_extensions')
          .select('id, credit_cents')
          .eq('source_id', claim.id).eq('extension_type', 'challenge');
        clawedCents = (exts ?? []).reduce((s, e) => s + (e.credit_cents ?? 0), 0);
        if (clawedCents > 0) {
          const { data: tRow } = await supabase.from('tenants')
            .select('stripe_customer_id').eq('id', claim.tenant_id).maybeSingle();
          await reverseRewardCredit(tRow?.stripe_customer_id, clawedCents);
        }
        if ((exts ?? []).length) {
          await supabase.from('subscription_extensions')
            .delete().eq('source_id', claim.id).eq('extension_type', 'challenge');
        }
      }
      await supabase.from('challenge_claims')
        .update({ status: 'rejected', reviewed_at: new Date().toISOString(), reward_redeemed_at: null })
        .eq('id', claim.id);
      await logAdminAction(request, g.caller?.id ?? null, 'challenge_reject',
        'challenge_claims', claim.id, { clawed_back_cents: clawedCents, reason: reason || null });
      return reply.send({ ok: true, rejected: true, clawed_back_cents: clawedCents });
    }

    // action === 'reward': aprueba un logro pendiente (sospechoso) -> pasa a
    // contar como completado y el cron aplicará la recompensa (si es de pago).
    await supabase.from('challenge_claims')
      .update({ status: 'rewarded', reviewed_at: new Date().toISOString() })
      .eq('id', claim.id);
    await logAdminAction(request, g.caller?.id ?? null, 'challenge_reward',
      'challenge_claims', claim.id, null);
    return reply.send({ ok: true, rewarded: true });
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

    // Detalle de retos: cada recompensa con su fecha y crédito €.
    const { data: exts } = await supabase.from('subscription_extensions')
      .select('days_extended, credit_cents, applied_at, extension_type')
      .eq('tenant_id', tenantId).eq('extension_type', 'challenge')
      .order('applied_at', { ascending: false }).limit(100);
    // Detalle de referidos: hitos conseguidos por los owners del tenant.
    const { data: owners } = await supabase.from('users')
      .select('id').eq('tenant_id', tenantId).eq('role', 'owner');
    const ownerIds = (owners ?? []).map((o) => o.id);
    let milestones = [];
    if (ownerIds.length) {
      const { data: rr } = await supabase.from('referral_milestone_rewards')
        .select('milestone_level, days_awarded, credit_cents, created_at').in('user_id', ownerIds)
        .order('created_at', { ascending: false }).limit(100);
      milestones = rr ?? [];
    }
    return reply.send({
      challenges_days: totals.challenges,
      referrals_days: totals.referrals,
      total_days: totals.total,
      challenges_eur: Number((totals.challenges_cents / 100).toFixed(2)),
      referrals_eur: Number((totals.referrals_cents / 100).toFixed(2)),
      total_eur: Number((totals.total_cents / 100).toFixed(2)),
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
      .select('days_awarded, credit_cents').limit(5000);
    const daysAwarded = (rewardRows ?? []).reduce((s, r) => s + (r.days_awarded ?? 0), 0);
    const milestonesAchieved = (rewardRows ?? []).length;
    // COSTE real del programa = suma de los CRÉDITOS Stripe concedidos por hitos
    // (N días de flota a la tarifa efectiva del cliente). Mismo criterio que Retos.
    const rewardCostEur = +((rewardRows ?? [])
      .reduce((s, r) => s + (r.credit_cents ?? 0), 0) / 100).toFixed(2);
    // Top referidores por nº de referidos VÁLIDOS (leaderboard de crecimiento).
    const validByReferrer = {};
    for (const r of validRows ?? []) {
      validByReferrer[r.referrer_user_id] = (validByReferrer[r.referrer_user_id] ?? 0) + 1;
    }
    const topIds = Object.entries(validByReferrer)
      .sort((a, b) => b[1] - a[1]).slice(0, 10);
    let topReferrers = [];
    if (topIds.length) {
      const { data: us } = await supabase.from('users')
        .select('id, name, email').in('id', topIds.map(([id]) => id));
      const nameById = {};
      for (const u of us ?? []) nameById[u.id] = u.name || u.email || '—';
      topReferrers = topIds.map(([id, count]) => ({ name: nameById[id] ?? '—', valid: count }));
    }
    const { count: openAlerts } = await supabase.from('referral_fraud_alerts')
      .select('id', { count: 'exact', head: true }).eq('status', 'open');
    // Pendientes de validar: en la cola de los 15 días (aún sin procesar).
    const { count: pendingValidation } = await supabase.from('referral_validation_queue')
      .select('id', { count: 'exact', head: true }).eq('processed', false);
    return reply.send({
      total, pending, valid, reverted, rejected,
      total_referrals: total,                                          // alias spec
      shares_total: sharesTotal ?? 0,
      pending_validation: pendingValidation ?? 0,                      // en cola de 15d
      distinct_referrers: distinctReferrers,
      conversion_rate: total ? +(valid / total).toFixed(3) : 0,        // válidos / total
      cpa_days: valid ? +(daysAwarded / valid).toFixed(1) : 0,         // días gratis por adquisición
      k_factor: distinctReferrers ? +(valid / distinctReferrers).toFixed(2) : 0, // válidos por referidor
      milestones_achieved: milestonesAchieved,
      days_awarded: daysAwarded,
      reward_cost_eur: rewardCostEur,                                  // € regalados
      top_referrers: topReferrers,                                     // leaderboard
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

  // Envía una notificación push a un usuario (busca sus tokens en device_tokens).
  async function notifyUser(userId, title, body, data = {}) {
    return notifyUsers([userId], title, body, data);
  }

  // Igual pero a varios usuarios a la vez (p. ej. todos los admins de plataforma).
  async function notifyUsers(userIds, title, body, data = {}) {
    const ids = [...new Set((userIds || []).filter(Boolean))];
    if (!ids.length || !pushEnabled()) return;
    const { data: toks } = await supabase.from('device_tokens').select('token').in('user_id', ids);
    const tokens = (toks || []).map((t) => t.token);
    if (!tokens.length) return;
    const result = await sendToTokens(tokens, { title, body, data }, app.log);
    if (result.attempted) markService('push', result.ok);
    if (result.invalidTokens.length) {
      await supabase.from('device_tokens').delete().in('token', result.invalidTokens);
    }
  }

  // Tokens de todos los admins de plataforma -> para avisos de soporte y límites.
  async function platformAdminIds() {
    const { data } = await supabase.from('users').select('id').eq('is_admin', true);
    return (data || []).map((a) => a.id);
  }

  // Aviso de LÍMITE al admin (push) cuando un semáforo de uso cruza su umbral
  // (Groq / recursos de Supabase). Con throttle: como mucho una vez cada 6h por
  // métrica; al recuperarse se limpia la marca para poder volver a avisar si recae.
  async function alertLimit(key, semaphores, title, bodyFn) {
    try {
      const s = semaphores.find((x) => x.key === key);
      const mark = `alert_last_${key}`;
      if (!s || s.status !== 'error') {
        await supabase.from('system_config').delete().eq('key', mark);
        return;
      }
      const { data } = await supabase.from('system_config')
        .select('value').eq('key', mark).maybeSingle();
      const last = data?.value ? Number(data.value) : 0;
      if (Date.now() - last < 6 * 60 * 60 * 1000) return;
      await supabase.from('system_config').upsert(
        { key: mark, value: String(Date.now()) }, { onConflict: 'key' });
      await notifyUsers(await platformAdminIds(), title, bodyFn(s), { type: 'limit', metric: key });
    } catch (e) { app.log.warn(`[alert-limit ${key}] ${e.message}`); }
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
      .select('id, milestone_level, days_awarded, credit_cents').eq('user_id', referrerUserId);
    const claimed = new Map((claimedRows ?? []).map((r) => [r.milestone_level, r]));
    const target = new Set(milestones.filter((m) => valid >= m.required).map((m) => m.level));

    // El premio solo se aplica si el referidor ya es cliente DE PAGO. En prueba se
    // difiere: al pasar a suscripción (webhook) se recalcula y se conceden los hitos
    // pendientes. Se aplica como CRÉDITO Stripe = N días de la FLOTA a la tarifa
    // efectiva del último pago, consumible en su próxima factura (no toca trial).
    const { data: refUser } = await supabase.from('users')
      .select('tenant_id').eq('id', referrerUserId).maybeSingle();
    const paying = refUser?.tenant_id ? await tenantIsPaying(refUser.tenant_id) : false;
    const { data: refTenant } = refUser?.tenant_id
      ? await supabase.from('tenants').select('stripe_customer_id, stripe_subscription_id').eq('id', refUser.tenant_id).maybeSingle()
      : { data: null };
    const customerId = refTenant?.stripe_customer_id ?? null;
    const fleetM = paying ? await fleetMonthlyCents(customerId, refTenant?.stripe_subscription_id) : 0;

    // Conceder hitos alcanzados que aún no se hayan concedido (solo si de pago).
    for (const m of milestones) {
      if (target.has(m.level) && !claimed.has(m.level) && paying) {
        const remaining = Math.max(0, annualMax - annualDays);
        const award = Math.min(m.days, remaining);
        const creditCents = Math.round(fleetM * award / 30);
        const txnId = creditCents > 0
          ? await applyRewardCredit(customerId, creditCents, `Referidos: hito ${m.level} (+${award} dias de flota)`)
          : null;
        await supabase.from('referral_milestone_rewards').insert({
          user_id: referrerUserId, milestone_level: m.level, required: m.required,
          days_awarded: award, credit_cents: creditCents, stripe_txn_id: txnId,
        });
        if (award > 0) {
          annualDays += award;
          await notifyUser(referrerUserId, '🎉 ¡Has ganado un descuento!',
            `Hito ${m.level} conseguido: ${(creditCents / 100).toFixed(2)}€ de descuento en tu próxima factura. ¡Sigue invitando!`,
            { type: 'referral_milestone', level: m.level });
        }
        app.log.info(`[referral] hito ${m.level} concedido a ${referrerUserId} (+${award} días, ${creditCents}c)`);
      }
    }
    // Revocar hitos que ya no correspondan (tras una reversión) — clawback (b):
    // se retira el crédito NO consumido; si ya se gastó, se asume (no se cobra más).
    for (const [lvl, row] of claimed) {
      if (!target.has(lvl)) {
        if ((row.credit_cents ?? 0) > 0 && customerId) await reverseRewardCredit(customerId, row.credit_cents);
        if ((row.days_awarded ?? 0) > 0) annualDays -= row.days_awarded;
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
  async function processReferralValidationQueue(opts = {}) {
    const { referrerUserId = null, force = false } = opts;
    const nowIso = new Date().toISOString();
    let vq = supabase.from('referral_validation_queue')
      .select('id, referral_id, referrals:referral_id(id, referred_tenant_id, validation_status, referrer_user_id)')
      .eq('processed', false).limit(500);
    if (!force) vq = vq.lte('scheduled_for', nowIso); // en modo test se ignora la espera de 15d
    const { data: due } = await vq;
    let validated = 0;
    let rejected = 0;
    for (const q of due ?? []) {
      const ref = q.referrals;
      // Modo scoped (prueba de UNA empresa): saltar los que no son de este owner.
      if (referrerUserId && ref?.referrer_user_id !== referrerUserId) continue;
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

  // Bandeja de webhooks (Mes 2, M2-5/M2-6): drena eventos pendientes de aplicar:
  //  - 'error'    → reintento de un fallo previo (tope de intentos → 'dead');
  //  - 'received' antiguos → eventos encolados en modo asíncrono (M2-5) o cuyo
  //    procesamiento inline crasheó a medias. El corte de edad evita competir con
  //    el handler síncrono que aún los está procesando en su propia request.
  // applyStripeEvent es idempotente, así que reprocesar es seguro aunque el
  // efecto ya se hubiera aplicado. El cron corto lo dispara cada pocos minutos →
  // su cadencia ES el backoff.
  const WEBHOOK_MAX_ATTEMPTS = 6;
  // Antigüedad mínima para drenar un 'received' (no pisar al handler síncrono).
  const WEBHOOK_RECEIVED_MIN_AGE_MS = process.env.WEBHOOK_RECEIVED_MIN_AGE_MS !== undefined
    ? Number(process.env.WEBHOOK_RECEIVED_MIN_AGE_MS) : 60000;

  async function applyQueuedEvent(row) {
    const attempts = (row.attempts ?? 0) + 1;
    try {
      const result = await handleStripeEvent(supabase, row.payload, {
        enqueueReferralValidation,
        recomputeReferrerMilestones,
        rejectPendingReferralValidation,
        revertReferralForTenant,
        log: app.log,
      });
      if (result.handled && result.tenant_id && SEAT_EVENTS.has(row.payload?.type)) {
        try { await enforceSeatLimit(result.tenant_id); } catch (_) {/* best-effort */}
      }
      await supabase.from('webhook_events')
        .update({ status: 'processed', processed_at: new Date().toISOString(),
          attempts, tenant_id: result.tenant_id ?? null })
        .eq('event_id', row.event_id);
      return 'recovered';
    } catch (e) {
      const dead = attempts >= WEBHOOK_MAX_ATTEMPTS;
      await supabase.from('webhook_events')
        .update({ status: dead ? 'dead' : 'error', attempts,
          last_error: String(e.message).slice(0, 500) })
        .eq('event_id', row.event_id);
      return dead ? 'exhausted' : 'failed';
    }
  }

  async function drainWebhookQueue({ limit = 50 } = {}) {
    const cols = 'event_id, type, attempts, payload';
    let rows = [];
    try {
      const cutoff = new Date(Date.now() - WEBHOOK_RECEIVED_MIN_AGE_MS).toISOString();
      const [errRes, recRes] = await Promise.all([
        supabase.from('webhook_events').select(cols)
          .eq('status', 'error').lt('attempts', WEBHOOK_MAX_ATTEMPTS)
          .order('received_at', { ascending: true }).limit(limit),
        supabase.from('webhook_events').select(cols)
          .eq('status', 'received').lt('received_at', cutoff)
          .order('received_at', { ascending: true }).limit(limit),
      ]);
      rows = [...(errRes.data ?? []), ...(recRes.data ?? [])];
    } catch (e) {
      app.log.warn(`[webhook-drain] bandeja no disponible: ${e.message}`);
      return { retried: 0, recovered: 0, failed: 0, exhausted: 0 };
    }
    let recovered = 0, failed = 0, exhausted = 0;
    for (const row of rows) {
      const r = await applyQueuedEvent(row);
      if (r === 'recovered') recovered++;
      else if (r === 'exhausted') exhausted++;
      else failed++;
    }
    return { retried: rows.length, recovered, failed, exhausted };
  }

  app.post('/api/v1/admin/cron/retry-webhooks', async (request, reply) => {
    const g = await cronOrAdmin(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const res = await drainWebhookQueue();
    await markCronRun('retry_webhooks');
    if (res.retried > 0) {
      await logAdminAction(request, g.caller?.id ?? null, 'retry_webhooks', 'webhook_events', null, res);
    }
    return reply.send({ ok: true, ...res });
  });

  // Feature flags (M2-7): allowlist de interruptores conmutables desde el panel.
  // `webhook_async` = procesar el webhook de Stripe de forma asíncrona (ACK +
  // drenaje por cron) en vez de inline. Default OFF (comportamiento síncrono).
  const KNOWN_FLAGS = {
    webhook_async: { def: false, label: 'Procesar webhooks de Stripe en asíncrono' },
  };

  app.get('/api/v1/admin/flags', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    invalidateFlagCache();
    const flags = {};
    for (const name of Object.keys(KNOWN_FLAGS)) {
      flags[name] = { on: await flagOn(name, KNOWN_FLAGS[name].def), label: KNOWN_FLAGS[name].label };
    }
    return reply.send({ flags });
  });

  app.post('/api/v1/admin/flags', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { name, on } = request.body ?? {};
    if (!Object.prototype.hasOwnProperty.call(KNOWN_FLAGS, name)) {
      return reply.code(400).send({ error: 'Flag desconocido' });
    }
    const value = (on === true || on === 'true' || on === 'on' || on === '1') ? 'on' : 'off';
    try {
      await supabase.from('system_config').upsert(
        { key: `flag_${name}`, value }, { onConflict: 'key' });
    } catch (e) {
      return reply.code(500).send({ error: `No se pudo guardar el flag: ${e.message}` });
    }
    invalidateFlagCache();
    await logAdminAction(request, g.caller?.id ?? null, 'flag_set', 'feature_flag', name, { name, value });
    return reply.send({ ok: true, name, on: value === 'on' });
  });

  app.post('/webhooks/stripe', async (request, reply) => {
    if (!stripe) return reply.code(500).send({ error: 'Stripe no configurado' });
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });

    const sig = request.headers['stripe-signature'];
    let event;
    try {
      event = stripe.webhooks.constructEvent(request.rawBody, sig, STRIPE_WEBHOOK_SECRET);
      markService('stripe', true); // firma verificada: la integración recibe eventos
    } catch (e) {
      markService('stripe', false); // secret incorrecto o payload manipulado
      return reply.code(400).send({ error: `Firma de webhook inválida: ${e.message}` });
    }

    // Idempotencia + durabilidad (Mes 2): registra el evento por su id ANTES de
    // procesarlo. Un reintento de Stripe ya 'processed' se ignora (no duplica);
    // un evento nuevo se persiste con su payload por si hay que reprocesarlo.
    // TODO best-effort: si la tabla webhook_events aún no existe en prod, el
    // webhook funciona igual que antes (nunca rompemos el camino del dinero).
    const eventId = event.id;
    let alreadyProcessed = false;
    let persisted = false; // ¿el evento está a salvo en la bandeja?
    try {
      const { data: ex } = await supabase.from('webhook_events')
        .select('status').eq('event_id', eventId).maybeSingle();
      if (ex?.status === 'processed') {
        alreadyProcessed = true;
      } else if (!ex) {
        await supabase.from('webhook_events')
          .insert({ event_id: eventId, type: event.type, status: 'received', payload: event });
        persisted = true;
      } else {
        persisted = true; // ya existía en 'received'/'error' → persistido
      }
    } catch (e) {
      app.log.warn(`[webhook_events] capa de durabilidad no disponible: ${e.message}`);
    }
    if (alreadyProcessed) {
      app.log.info(`[stripe-webhook] ${eventId} duplicado ignorado`);
      return reply.send({ received: true, duplicate: true });
    }

    // Modo ASÍNCRONO (M2-5, tras el feature flag `webhook_async`): si el evento
    // está a salvo en la bandeja, ACK inmediato a Stripe y lo aplica el cron de
    // drenaje. Reduce el timeout del webhook y desacopla el ACK del trabajo. Si
    // NO se pudo persistir (tabla ausente / BD caída), caemos a síncrono para no
    // perder NUNCA el evento (el camino del dinero manda sobre la latencia).
    if (persisted && await flagOn('webhook_async', false)) {
      app.log.info(`[stripe-webhook] ${eventId} encolado (async)`);
      return reply.send({ received: true, queued: true });
    }

    try {
      // Dominio de billing (billing.js): aplica el evento a `tenants` y ejecuta
      // los efectos de referidos (encolar validación 15d / clawback al cancelar).
      // Las funciones de referidos son closures sobre supabase → se inyectan.
      const result = await handleStripeEvent(supabase, event, {
        enqueueReferralValidation,
        recomputeReferrerMilestones,
        rejectPendingReferralValidation,
        revertReferralForTenant,
        log: request.log,
      });
      app.log.info(`[stripe-webhook] ${result.type} handled=${result.handled} tenant=${result.tenant_id ?? '-'}`);
      // Aplica el cupo de asientos (drivers_limit + bloqueo de los más nuevos)
      // tras un pago/cambio de suscripción (p. ej. al acabar la prueba).
      if (result.handled && result.tenant_id && SEAT_EVENTS.has(event?.type)) {
        try { await enforceSeatLimit(result.tenant_id); } catch (_) {/* best-effort */}
      }
      // Marca el evento como procesado (best-effort).
      try {
        await supabase.from('webhook_events')
          .update({ status: 'processed', processed_at: new Date().toISOString(),
            tenant_id: result.tenant_id ?? null })
          .eq('event_id', eventId);
      } catch (e) { app.log.warn(`[webhook_events] no se pudo marcar processed: ${e.message}`); }
      return reply.send({ received: true, ...result });
    } catch (e) {
      request.log.error(e);
      // Deja rastro del fallo para reproceso/diagnóstico (best-effort). Devolver
      // 500 hace que Stripe reintente; el evento sigue en 'received'/'error'.
      try {
        await supabase.from('webhook_events')
          .update({ status: 'error', last_error: String(e.message).slice(0, 500) })
          .eq('event_id', eventId);
      } catch { /* la tabla puede no existir aún */ }
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
