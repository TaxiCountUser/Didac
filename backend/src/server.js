import 'dotenv/config';
import { pathToFileURL } from 'node:url';
import Fastify from 'fastify';
import cors from '@fastify/cors';
import { createClient } from '@supabase/supabase-js';

const PORT = Number(process.env.BACKEND_PORT || 3000);
const HOST = '0.0.0.0';

const SUPABASE_URL = process.env.SUPABASE_URL || 'http://kong:8000';
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || '';

/**
 * Construye la instancia de Fastify (sin escuchar).
 * Permite testear con `app.inject(...)` sin abrir un puerto.
 */
export async function buildApp() {
  const app = Fastify({ logger: process.env.NODE_ENV !== 'test' });

  await app.register(cors, { origin: true });

  const supabase =
    SUPABASE_URL && SUPABASE_SERVICE_ROLE_KEY
      ? createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
          auth: { autoRefreshToken: false, persistSession: false },
        })
      : null;
  app.decorate('supabase', supabase);

  // --- Health ---
  app.get('/health', async () => ({
    status: 'ok',
    service: 'taxicount-backend',
    timestamp: new Date().toISOString(),
  }));

  // --- Transcripción (mock Fase 0) ---
  app.post('/api/v1/transcribe', async (request) => ({
    text: 'transcripción pendiente de implementar',
    received: request.body ?? null,
  }));

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

// Solo arranca el servidor si se ejecuta directamente (no al importar en tests).
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  start();
}
