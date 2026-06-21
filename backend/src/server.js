import 'dotenv/config';
import { pathToFileURL } from 'node:url';
import { randomBytes, createHash } from 'node:crypto';
import Fastify from 'fastify';
import cors from '@fastify/cors';
import multipart from '@fastify/multipart';
import { createClient } from '@supabase/supabase-js';

import { parseTransactionText } from './parser.js';
import { applyStripeEvent, planForPrice } from './billing.js';

const PORT = Number(process.env.BACKEND_PORT || 3000);
const HOST = '0.0.0.0';

const SUPABASE_URL = process.env.SUPABASE_URL || 'http://kong:8000';
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || '';
const OPENAI_API_KEY = process.env.OPENAI_API_KEY || '';

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

// Transcriptor real (Whisper de OpenAI). Import dinámico para no exigir el
// paquete cuando se usa un mock en tests.
async function defaultTranscribe({ buffer, filename }) {
  if (!OPENAI_API_KEY) throw new Error('OPENAI_API_KEY no configurada');
  const { default: OpenAI, toFile } = await import('openai');
  const client = new OpenAI({ apiKey: OPENAI_API_KEY });
  const file = await toFile(buffer, filename || 'audio.m4a');
  const res = await client.audio.transcriptions.create({ file, model: 'whisper-1' });
  return { text: res.text, confidence: 0.95 };
}

/**
 * @param {object} [options]
 * @param {(input:{buffer?:Buffer,filename?:string,mockText?:string})=>Promise<{text:string,confidence:number}>} [options.transcribe]
 *        Permite inyectar un transcriptor (mock) en tests.
 */
export async function buildApp(options = {}) {
  const app = Fastify({ logger: process.env.NODE_ENV !== 'test' });
  await app.register(cors, { origin: true });
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

  const supabase =
    SUPABASE_URL && SUPABASE_SERVICE_ROLE_KEY
      ? createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
          auth: { autoRefreshToken: false, persistSession: false },
        })
      : null;
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
      .select('id, role, tenant_id, daily_transcription_count, transcription_count_date')
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
    timestamp: new Date().toISOString(),
  }));

  // --- Transcripción + parseo (Fase 2) ---
  app.post('/api/v1/transcribe', async (request, reply) => {
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });

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
      return reply.send({ ...cached, parsed: parseTransactionText(cached.text), cached: true });
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
          : transcribe({ buffer, filename });
      try {
        result = await withTimeout(run(), WHISPER_TIMEOUT_MS);
      } catch (e) {
        request.log.warn(`Whisper falló (${e.message}); reintentando…`);
        result = await withTimeout(run(), WHISPER_TIMEOUT_MS);
      }
    } catch (e) {
      return reply.code(502).send({ error: 'Transcripción no disponible', detail: e.message });
    }

    transcriptionCache.set(cacheKey, result);
    return reply.send({ ...result, parsed: parseTransactionText(result.text), cached: false });
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

    // Límite de conductores según el plan contratado (Fase 4).
    const { data: tenant } = await supabase
      .from('tenants')
      .select('drivers_limit')
      .eq('id', caller.tenant_id)
      .single();
    const limit = tenant?.drivers_limit;
    if (limit !== null && limit !== undefined) {
      const { count } = await supabase
        .from('users')
        .select('id', { count: 'exact', head: true })
        .eq('tenant_id', caller.tenant_id)
        .eq('role', 'driver');
      if ((count ?? 0) >= limit) {
        return reply.code(403).send({ error: 'Has alcanzado el límite de conductores de tu plan' });
      }
    }

    const tempPassword = generateTempPassword();
    const { data: created, error: createErr } = await supabase.auth.admin.createUser({
      email,
      password: tempPassword,
      email_confirm: true,
      user_metadata: { role: 'driver', tenant_id: caller.tenant_id, name: name ?? null },
    });
    if (createErr) {
      const code = /already|registered|exists/i.test(createErr.message || '') ? 409 : 400;
      return reply.code(code).send({ error: createErr.message });
    }

    app.log.info(`[create-driver] ${email} en tenant ${caller.tenant_id}. Pwd temporal: ${tempPassword}`);
    return reply.code(201).send({ id: created.user.id, email, tenant_id: caller.tenant_id, tempPassword });
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

  // --- Webhook de Stripe (Fase 4) ---
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
      return reply.send({ received: true, ...result });
    } catch (e) {
      request.log.error(e);
      return reply.code(500).send({ error: 'Error procesando el evento', detail: e.message });
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
