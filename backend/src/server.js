import 'dotenv/config';
import { pathToFileURL } from 'node:url';
import { randomBytes } from 'node:crypto';
import Fastify from 'fastify';
import cors from '@fastify/cors';
import { createClient } from '@supabase/supabase-js';

// Genera una contraseña temporal razonablemente fuerte.
function generateTempPassword() {
  return 'Tx' + randomBytes(9).toString('base64url') + '9!';
}

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

  // --- Invitar conductor (Fase 1) ---
  // Solo un Owner autenticado puede crear un driver en SU tenant.
  // El llamante envía su access token en Authorization: Bearer <token>.
  // Usamos service_role para crear el usuario auth; el trigger de BD
  // crea el perfil public.users con rol 'driver' en el tenant correcto.
  app.post('/api/v1/drivers', async (request, reply) => {
    if (!supabase) {
      return reply.code(500).send({ error: 'Supabase no configurado en el backend' });
    }

    const auth = request.headers['authorization'] || '';
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : null;
    if (!token) {
      return reply.code(401).send({ error: 'Falta el token de autenticación' });
    }

    const { email, name } = request.body ?? {};
    if (!email || typeof email !== 'string') {
      return reply.code(400).send({ error: 'email es obligatorio' });
    }

    // 1. Verificar el token y obtener el usuario llamante
    const { data: userData, error: userErr } = await supabase.auth.getUser(token);
    if (userErr || !userData?.user) {
      return reply.code(401).send({ error: 'Token inválido' });
    }
    const callerId = userData.user.id;

    // 2. Cargar el perfil del llamante (service_role omite RLS)
    const { data: caller, error: profErr } = await supabase
      .from('users')
      .select('role, tenant_id')
      .eq('id', callerId)
      .single();
    if (profErr || !caller) {
      return reply.code(403).send({ error: 'Perfil del llamante no encontrado' });
    }
    if (caller.role !== 'owner') {
      return reply.code(403).send({ error: 'Solo un Owner puede invitar conductores' });
    }

    // 3. Crear el usuario driver con service_role
    const tempPassword = generateTempPassword();
    const { data: created, error: createErr } = await supabase.auth.admin.createUser({
      email,
      password: tempPassword,
      email_confirm: true,
      user_metadata: {
        role: 'driver',
        tenant_id: caller.tenant_id,
        name: name ?? null,
      },
    });
    if (createErr) {
      const code = /already|registered|exists/i.test(createErr.message || '') ? 409 : 400;
      return reply.code(code).send({ error: createErr.message || 'No se pudo crear el conductor' });
    }

    // En desarrollo: registrar la contraseña temporal en consola.
    app.log.info(
      `[create-driver] Conductor ${email} creado en tenant ${caller.tenant_id}. ` +
        `Contraseña temporal: ${tempPassword}`
    );

    return reply.code(201).send({
      id: created.user.id,
      email,
      tenant_id: caller.tenant_id,
      // Solo en desarrollo (en prod se enviaría por email):
      tempPassword,
    });
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

// Solo arranca el servidor si se ejecuta directamente (no al importar en tests).
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  start();
}
