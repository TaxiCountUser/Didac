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
import { llmParse, mergeParsed, llmParseAgenda } from './llm_parser.js';
import { sendToTokens, pushEnabled } from './push.js';
import { pushText } from './push_i18n.js';
import { handleStripeEvent, planForPrice } from './billing.js';
import { createSecurityLog } from './security_log.js';
import { createRewards } from './rewards.js';
import { createMonitoring } from './monitoring.js';
import { registerRetosRoutes } from './retos.js';
import { registerFraudRoutes } from './fraud.js';
import { registerReferralsRoutes } from './referrals.js';
import { registerReportsRoutes } from './reports_routes.js';
import { registerIncidentsRoutes } from './incidents.js';
import { registerSubscriptionRoutes } from './subscription.js';
import { registerOdometerRoutes } from './odometer.js';
import { registerAuditViewerRoutes } from './audit_viewers.js';
import { registerAdminUsersRoutes } from './admin_users.js';
import { registerCompaniesRoutes } from './companies.js';
import { registerFlagsRoutes } from './flags.js';
import { registerFinancialRoutes } from './financial.js';
import { registerMetricsRoutes } from './metrics.js';
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
const STRIPE_PRICE_SEAT_MONTHLY = process.env.STRIPE_PRICE_SEAT_MONTHLY || '';
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
// conductor: "1 mes-asiento gratis". Por defecto 300 = 3 € (fallback; el real lo lee seatBaseRate de Stripe).

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

// --- Agenda (opción oculta): parseo dedicado con IA cuando el dictado empieza
// por "apunta en la agenda" / "apunta a l'agenda" / "add to agenda". Es ADITIVO:
// solo se activa con esa muletilla; el flujo de carreras/gastos no se toca.
const AGENDA_TRIGGER = /apunta(r)?\s+(a|en)\s+l['’a]?\s*agenda|add to (the )?agenda/i;
function isAgendaDictation(text) { return AGENDA_TRIGGER.test(text || ''); }
// Fecha/hora de referencia en horario de ESPAÑA (hoy todos los tenants son de
// España). Formato "YYYY-MM-DD HH:MM" para que el LLM resuelva "mañana a las 3".
function agendaNowRef() {
  try {
    const p = new Intl.DateTimeFormat('sv-SE', {
      timeZone: 'Europe/Madrid', year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', hour12: false,
    }).format(new Date());
    return p.replace(',', ''); // sv-SE ya da "YYYY-MM-DD HH:MM"
  } catch { return new Date().toISOString(); }
}
// Best-effort: si no hay LLM o falla, devuelve null y el frontend usa su heurística.
async function maybeParseAgenda(text, { log, markGroqRateLimit } = {}) {
  if (!isAgendaDictation(text)) return null;
  if (!LLM_PARSE_MODEL || !OPENAI_API_KEY) return null;
  try {
    return await withTimeout(
      llmParseAgenda(text, {
        apiKey: OPENAI_API_KEY, baseURL: OPENAI_BASE_URL, model: LLM_PARSE_MODEL,
        nowRef: agendaNowRef(), onRateLimit: markGroqRateLimit,
      }),
      LLM_PARSE_TIMEOUT_MS,
    );
  } catch (e) {
    log?.warn?.(`Agenda LLM parse falló (${e.message})`);
    return null;
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
      if (!b.logged) { b.logged = true; logSecurityEvent(request, 'rate_limit', { status: 429 }); }
      return reply.code(429).send({ error: 'Demasiadas peticiones, prueba en un minuto' });
    }
  });

  // Trace ID por petición (Fastify lo genera): al header de respuesta y a los logs
  // de seguridad, para poder correlacionar una petición con Better Stack/Sentry.
  app.addHook('onRequest', async (request, reply) => { reply.header('x-trace-id', request.id); });

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

  // logSecurityEvent (capa B) vive en ./security_log.js (Fase A del troceig).
  // Se instancia aquí, en cuanto supabase/app están listos, para que esté
  // disponible en todos los handlers/middleware; firma y comportamiento idénticos.
  const { logSecurityEvent } = createSecurityLog({ supabase, log: app.log });

  // Recompensas (crédito Stripe) viven en ./rewards.js (Fase A del troceig). Se
  // instancian aquí; los 4 helpers que se inyectan (tenantIsPaying, refConfig,
  // milestonesFrom, notifyUser) son `function` declarations del closure → están
  // hoisted, así que ya son referencias válidas aunque su código aparezca más abajo.
  // Los llamadores de estas funciones son todos handlers diferidos (request time).
  const {
    seatBaseRate, applyRewardCredit, reverseRewardCredit,
    applyPendingChallengeCredits, freeDaysForTenant, recomputeReferrerMilestones,
  } = createRewards({
    stripe, supabase, log: app.log,
    tenantIsPaying, refConfig, milestonesFrom, notifyUser,
  });

  // Monitorización (semáforos + uptime) vive en ./monitoring.js (Fase A del
  // troceig). `probeDb` es `function` hoisted del closure (también lo usa
  // /overview), por eso se inyecta; `pushEnabled` lo importa el módulo directo.
  const { markService, computeSemaphores } = createMonitoring({
    supabase, log: app.log, probeDb,
  });

  // Dashboard financiero (admin, el núcleo): plugin en ./financial.js (Fase B). Se
  // registra ANTES que retos/companies porque DEVUELVE readGlobalRevenue (lo usa el
  // summary de retos) y readTenantRevenue (ficha de empresa en companies).
  const { readGlobalRevenue, readTenantRevenue } = registerFinancialRoutes(app, {
    supabase, stripe, adminGuard, probeDb, log: app.log,
  });

  // Retos (challenges): plugin de rutas en ./retos.js (Fase B). Se registra aquí;
  // los guards (adminGuard/getCaller/logAdminAction) son `function` hoisted y
  // reverseRewardCredit ya está instanciado arriba (rewards.js). readGlobalRevenue
  // (financial.js) lo usa /admin/challenges/summary.
  registerRetosRoutes(app, {
    supabase, adminGuard, getCaller, logAdminAction, reverseRewardCredit, log: app.log,
    readGlobalRevenue,
  });

  // Centro de fraude: plugin de rutas en ./fraud.js (Fase B). 3 endpoints (visor
  // unificado de alertas). Deps mínimas; adminGuard/logAdminAction son hoisted.
  registerFraudRoutes(app, { supabase, adminGuard, logAdminAction });

  // Referidos: plugin de rutas en ./referrals.js (Fase B, 15 endpoints + anti-fraude
  // de referidos). refConfig/milestonesFrom viven aquí (los comparte rewards.js →
  // evita circular) y se inyectan; recomputeReferrerMilestones viene de rewards.js.
  registerReferralsRoutes(app, {
    supabase, adminGuard, getCaller, logAdminAction,
    refConfig, milestonesFrom, recomputeReferrerMilestones,
  });

  // Informes Excel/PDF + Import: plugin de rutas en ./reports_routes.js (Fase B).
  // Delega en reports.js/importer.js/llm_parser.js (imports propios); se inyectan
  // supabase/getCaller/rateLimited/withTimeout + las constantes module-level.
  registerReportsRoutes(app, {
    supabase, getCaller, rateLimited, withTimeout,
    REPORT_TIMEOUT_MS, XLSX_MIME, OPENAI_API_KEY, OPENAI_BASE_URL, LLM_PARSE_MODEL,
  });

  // Incidencias + push: plugin de rutas en ./incidents.js (Fase B). Panel admin de
  // incidencias + endpoints de push (incidencia/chat de flota). notifyUsers/notifyUser
  // (core, compartidos) y markService (monitoring) se inyectan.
  registerIncidentsRoutes(app, {
    supabase, adminGuard, getCaller, logAdminAction,
    notifyUsers, notifyUser, markService, platformAdminIds,
  });

  // Suscripción Stripe (asientos/cupones/checkout/portal): plugin en ./subscription.js
  // (Fase B). Agrupa toda la lógica de cupón; DEVUELVE syncScheduledCoupon porque lo
  // llama el cron/vigía en server.js. Los helpers de asientos (compartidos con
  // billing.js) y las constantes Stripe se inyectan.
  const { syncScheduledCoupon } = registerSubscriptionRoutes(app, {
    supabase, stripe, log: app.log, adminGuard, getCaller, logAdminAction,
    seatCount, setSeatQuantity, enforceSeatLimit,
    STRIPE_PRICE_SEAT_MONTHLY, STRIPE_PRICE_SEAT_YEARLY, STRIPE_SUCCESS_URL, STRIPE_CANCEL_URL,
    MAX_SEATS,
  });

  // Corrección de odómetro (admin): plugin de rutas en ./odometer.js (Fase B).
  registerOdometerRoutes(app, { supabase, adminGuard, logAdminAction });

  // Visores de auditoría (admin, solo lectura): plugin en ./audit_viewers.js (Fase B).
  registerAuditViewerRoutes(app, { supabase, adminGuard });

  // Administradores + usuarios (admin): plugin en ./admin_users.js (Fase B).
  registerAdminUsersRoutes(app, { supabase, adminGuard, logAdminAction });

  // Gestión de empresas (admin): plugin en ./companies.js (Fase B). closeTenantAccount
  // vive dentro del módulo; readTenantRevenue (financiero) se queda en server.js e inyecta.
  registerCompaniesRoutes(app, {
    supabase, stripe, log: app.log, adminGuard, getCaller, logAdminAction,
    readTenantRevenue, freeDaysForTenant,
  });

  // Feature flags (admin): plugin en ./flags.js (Fase B). La infra de flags
  // (loadFlags/flagOn/invalidateFlagCache) se queda en server.js (la comparte el
  // webhook async) y se inyecta.
  registerFlagsRoutes(app, { supabase, adminGuard, logAdminAction, flagOn, invalidateFlagCache });

  // Métricas de uso (admin): plugin en ./metrics.js (Fase B). supabaseMetrics se
  // queda en server.js (lo comparte el cron de semáforos) y se inyecta.
  registerMetricsRoutes(app, { supabase, adminGuard, supabaseMetrics });

  // Caché de transcripciones en memoria: clave userId:hash(audio) -> {text,confidence}
  const transcriptionCache = new Map();

  // Verifica el JWT y devuelve el perfil del llamante (o null).
  async function getCaller(request) {
    const auth = request.headers['authorization'] || '';
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : null;
    if (!token || !supabase) return null;
    const { data, error } = await supabase.auth.getUser(token);
    if (error || !data?.user) {
      // Token presente pero inválido/caducado/manipulado: señal de seguridad
      // (con throttle por IP para no inundar si un cliente reintenta un caducado).
      if (!secThrottled(`invtok:${request.ip}`)) {
        logSecurityEvent(request, 'invalid_token', { status: 401, details: { reason: (error?.message ?? 'no user').slice(0, 120) } });
      }
      return null;
    }
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
      const agenda = await maybeParseAgenda(cached.text, { log: request.log, markGroqRateLimit });
      return reply.send({ ...cached, parsed, ...(agenda ? { agenda } : {}), cached: true });
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
    const agenda = await maybeParseAgenda(result.text, { log: request.log, markGroqRateLimit });
    return reply.send({ ...result, parsed, ...(agenda ? { agenda } : {}), cached: false });
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
      logSecurityEvent(request, 'rate_limit', { status: 429, details: { scope: 'login_brute_force', username: u.slice(0, 60) } });
      return reply.code(429).send({ error: 'Demasiados intentos, prueba en un minuto' });
    }
    // Respuesta genérica para no revelar si el usuario existe.
    const genErr = () => {
      logSecurityEvent(request, 'login_failed', { status: 401, details: { username: u.slice(0, 60) } });
      return reply.code(401).send({ error: 'Usuario o contraseña incorrectos' });
    };
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

  // --- Reporte de login FALLIDO de email/Google (capa B, fase 2). Estos logins
  // pasan por Supabase Auth DIRECTAMENTE desde el frontend, así que el backend no
  // los ve; el cliente los reporta aquí para que salgan en la pestaña "Logs". Es
  // ADVISORY (reportado por el cliente): la fuente autoritativa son los logs de
  // Auth de Supabase. PÚBLICO (el login ha fallado, no hay sesión), pero acotado
  // por IP y con throttle para no inundar la tabla. Solo metadatos: NUNCA la
  // contraseña. Reutiliza el tipo 'login_failed' con details.method (coherente
  // con el login por usuario, que ya lo registra). Siempre 200 (no es un oráculo).
  app.post('/api/v1/security/auth-failed', async (request, reply) => {
    const b = request.body ?? {};
    const method = ['email', 'google'].includes(String(b.method)) ? String(b.method) : 'email';
    if (rateLimited(`authfail:${request.ip}`, 20, 60000)) return reply.send({ ok: true });
    if (!secThrottled(`authfail:${request.ip}:${method}`, 60000)) {
      const email = (b.email == null ? '' : String(b.email)).trim().slice(0, 80) || null;
      const reason = (b.reason == null ? '' : String(b.reason)).slice(0, 120) || null;
      logSecurityEvent(request, 'login_failed', { status: 401, details: { method, email, reason } });
    }
    return reply.send({ ok: true });
  });

  // Telemetría de errores del CLIENTE (mig. 082): la app reporta sus excepciones
  // (fire-and-forget) para verlas AGREGADAS en Auditoría y detectar recurrentes.
  // Autenticado (los errores ocurren dentro de la app). Throttle por usuario+mensaje
  // (1/min) para no inundar si un error entra en bucle. Solo metadatos técnicos.
  app.post('/api/v1/client-error', async (request, reply) => {
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    const b = request.body ?? {};
    const message = (b.message == null ? '' : String(b.message)).trim().slice(0, 300);
    if (!message) return reply.send({ ok: true });
    if (secThrottled(`clienterr:${caller.id}:${message.slice(0, 60)}`, 60000)) {
      return reply.send({ ok: true });
    }
    supabase.from('client_errors').insert({
      message,
      screen: (b.screen == null ? '' : String(b.screen)).slice(0, 80) || null,
      platform: (b.platform == null ? '' : String(b.platform)).slice(0, 30) || null,
      app_version: (b.app_version == null ? '' : String(b.app_version)).slice(0, 30) || null,
      user_id: caller.id,
      tenant_id: caller.tenant_id ?? null,
    }).then(() => {}, (e) => app.log.warn(`[client-error] ${e.message}`));
    return reply.send({ ok: true });
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
      else if (!caller.is_admin) {
        result = { code: 403, error: 'Solo un administrador puede acceder' };
        // Usuario autenticado NO admin que toca una ruta admin: escalada.
        logSecurityEvent(request, 'privilege_escalation', { status: 403, actorId: caller.id, tenantId: caller.tenant_id });
      } else result = { caller };
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

  // Registro de un evento de SEGURIDAD (capa B) en security_events. Best-effort y
  // NUNCA guarda cuerpo/headers de la petición (evita secretos/PII). El throttle
  // evita inundar la tabla con repeticiones (p. ej. un cliente con token caducado).
  const _secThrottle = new Map();
  function secThrottled(key, ms = 300000) {
    const now = Date.now();
    const last = _secThrottle.get(key);
    if (last && now - last < ms) return true;
    _secThrottle.set(key, now);
    return false;
  }

  // ============================================================
  // Loop #6 - Informes de error enviados desde la app.
  // Van SOLO al ADMIN (panel completo). NO hay copia al jefe: ningún screen
  // no-admin lee error_reports (la RLS de owner quedó sin uso; limpiable por
  // migración). Es una tabla aparte de incidents -> no sale en "Mensajes al jefe".
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
    const locale = b.locale ? String(b.locale).slice(0, 5).toLowerCase() : null;
    // El tenant SIEMPRE es el del llamante (no se acepta del body: evitar que se
    // marque el token con un tenant ajeno).
    const tenantId = caller.tenant_id ?? null;
    const { error } = await supabase.from('device_tokens').upsert({
      user_id: caller.id,
      tenant_id: tenantId,
      token,
      platform,
      ...(locale ? { locale } : {}),
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

    // Push SOLO a los admins (van únicamente al panel de administración; no hay
    // copia al jefe: ningún screen no-admin lee error_reports).
    try {
      const { data: me } = await supabase.from('users').select('name, email').eq('id', caller.id).maybeSingle();
      const reporter = me?.name || me?.email || 'Un usuario';
      const preview = description.length > 120 ? `${description.slice(0, 117)}…` : description;
      const { data: admins } = await supabase.from('users').select('id').eq('is_admin', true);
      for (const a of admins ?? []) {
        await notifyUser(a.id, 'error_report_admin', { reporter, preview },
          { type: 'error_report', report_id: String(row?.id ?? '') });
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
        await notifyUser(row.user_id, 'error_resolved', {},
          { type: 'error_report_resolved', report_id: String(row.id) });
      } catch { /* no-op */ }
    }
    return reply.send({ ok: true, id: row.id, status });
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
    } else if (mode === 'reset_balance') {
      // Poner el saldo del cliente a 0 (limpiar créditos acumulados en pruebas).
      // Sin confusión de signos: el backend calcula la transacción que lo anula.
      if (!stripe || !tenant.stripe_customer_id) return reply.code(400).send({ error: 'La empresa no tiene cliente Stripe' });
      const cust = await stripe.customers.retrieve(tenant.stripe_customer_id);
      const bal = cust?.balance ?? 0;
      out.reset_from_cents = bal;
      if (bal !== 0) {
        await stripe.customers.createBalanceTransaction(tenant.stripe_customer_id, {
          amount: -bal, currency: 'eur', description: 'Reset de saldo (pruebas)',
        });
      }
    } else {
      return reply.code(400).send({ error: 'mode debe ser challenge, referrals o reset_balance' });
    }

    // Desglose de la tarifa de flota (debug): qué líneas de factura cuenta y su
    // aportación mensual, para verificar el cálculo del crédito.
    if (stripe && tenant.stripe_customer_id) {
      const rate = await seatBaseRate(tenant.stripe_subscription_id);
      out.per_seat_eur = +(rate.perSeatCents / 100).toFixed(2);
      out.fleet_monthly_eur = +((rate.perSeatCents * rate.seats) / 100).toFixed(2);
      out.seats = rate.seats;
      out.drivers_limit = tenant.drivers_limit;
      // Saldo actual del cliente (negativo = crédito pendiente de consumir).
      try {
        const cust = await stripe.customers.retrieve(tenant.stripe_customer_id);
        out.customer_balance_cents = cust?.balance ?? 0;
      } catch { /* sin balance */ }
    }
    await logAdminAction(request, g.caller?.id ?? null, 'test_rewards', 'tenant', id, out);
    return reply.send(out);
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
        const mKey = m === 'expired' ? 'maint_expired' : (m === '0' ? 'maint_today' : 'maint_soon');
        await notifyUsers(ownerIds, mKey,
          { label, kindKey: kind, date: _fmtD(dueDate), days: daysLeft },
          { type: 'maintenance', vehicleId: v.id });
        sent++;
      }

      if (v.last_revision_km != null && v.revision_interval_km) {
        const target = Number(v.last_revision_km) + Number(v.revision_interval_km);
        const current = await vehicleCurrentKm(v);
        if (current != null) {
          const kmLeft = target - current;
          const m = kmMilestone(kmLeft);
          if (m && await recordMaintReminder(v.id, 'revision_km', String(target), m)) {
            await notifyUsers(ownerIds, kmLeft > 0 ? 'maint_revision_soon' : 'maint_revision_due',
              { label, km: kmLeft, target }, { type: 'maintenance', vehicleId: v.id });
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
      if (unit == null || Number.isNaN(unit)) unit = interval === 'year' ? 3000 : 300;
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

  app.get('/api/v1/admin/semaphores', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    return reply.send({ semaphores: await computeSemaphores() });
  });

  // Adopción de la ENTRADA de datos HOY: cuántas transacciones se crearon por VOZ
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
    // logHistory: la vigía (cada 15 min) registra la muestra en service_status_log.
    const semaphores = await computeSemaphores({ logHistory: true });
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

  // ============================================================
  // Referidos v2 — Iteración 3: validación, hitos y reversión.
  // Premio = días gratis al TENANT del referidor (extiende trial_ends_at), con
  // tope anual configurable. Idempotente: recalcula hitos desde el nº de
  // referidos VÁLIDOS, concediendo los que falten y revocando los que ya no
  // correspondan (p. ej. tras una reversión por cancelación temprana).
  // ============================================================

  // Envía una notificación push a un usuario (busca sus tokens en device_tokens).
  async function notifyUser(userId, key, args = {}, data = {}) {
    return notifyUsers([userId], key, args, data);
  }

  // Notificación LOCALIZADA: `key` + `args` (ver push_i18n.js). Agrupa los tokens
  // de los destinatarios por idioma (device_tokens.locale) y traduce el texto para
  // cada grupo, porque el SO muestra la push con la app cerrada (traducción en el
  // servidor). Para textos ya construidos que NO se traducen, usar notifyUsersRaw.
  async function notifyUsers(userIds, key, args = {}, data = {}) {
    const ids = [...new Set((userIds || []).filter(Boolean))];
    if (!ids.length || !pushEnabled()) return;
    const { data: toks } = await supabase.from('device_tokens').select('token, locale').in('user_id', ids);
    if (!toks?.length) return;
    const byLocale = {};
    for (const t of toks) (byLocale[t.locale || 'es'] ||= []).push(t.token);
    let anyAttempt = false; let anyOk = true; const invalid = [];
    for (const [loc, tokens] of Object.entries(byLocale)) {
      const { title, body } = pushText(loc, key, args);
      const result = await sendToTokens(tokens, { title, body, data }, app.log);
      if (result.attempted) { anyAttempt = true; anyOk = anyOk && result.ok; }
      if (result.invalidTokens?.length) invalid.push(...result.invalidTokens);
    }
    if (anyAttempt) markService('push', anyOk);
    if (invalid.length) await supabase.from('device_tokens').delete().in('token', invalid);
  }

  // Igual pero con title/body YA construidos (sin traducir): para avisos internos
  // de plataforma (alertas de límites a los admins), donde el texto es dinámico.
  async function notifyUsersRaw(userIds, title, body, data = {}) {
    const ids = [...new Set((userIds || []).filter(Boolean))];
    if (!ids.length || !pushEnabled()) return;
    const { data: toks } = await supabase.from('device_tokens').select('token').in('user_id', ids);
    const tokens = (toks || []).map((t) => t.token);
    if (!tokens.length) return;
    const result = await sendToTokens(tokens, { title, body, data }, app.log);
    if (result.attempted) markService('push', result.ok);
    if (result.invalidTokens?.length) {
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
      await notifyUsersRaw(await platformAdminIds(), title, bodyFn(s), { type: 'limit', metric: key });
    } catch (e) { app.log.warn(`[alert-limit ${key}] ${e.message}`); }
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
          await notifyUser(ref.referrer_user_id, 'referral_validated', {},
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
