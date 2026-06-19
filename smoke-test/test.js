// ============================================================
// TaxiCount - Smoke test E2E (Fase 0)
//
// Valida de extremo a extremo:
//   1. Conexión a Supabase local.
//   2. Login como owner (seed).
//   3. owner crea un vehículo.
//   4. Login como driver.
//   5. driver inserta una transacción.
//   6. owner ve la transacción del driver (RLS owner ve su tenant).
//   7. driver NO ve transacciones de otro tenant (aislamiento RLS).
//
// Exit 0 si todo pasa; exit 1 con mensaje si algo falla.
// ============================================================
import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = process.env.SUPABASE_URL || 'http://localhost:54321';
const ANON_KEY =
  process.env.SUPABASE_ANON_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlLWRlbW8iLCJpYXQiOjE3MDAwMDAwMDAsImV4cCI6MjAwMDAwMDAwMH0.ZxBhVEYye2lqm5NDdkey-JP6uTHcqvZriXUoBtyQniY';
const SERVICE_KEY =
  process.env.SUPABASE_SERVICE_ROLE_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UtZGVtbyIsImlhdCI6MTcwMDAwMDAwMCwiZXhwIjoyMDAwMDAwMDAwfQ.8T3kmJ5SaqY3bVmU02ZJ4MIoHe5z7R4qQ4T9VqJA8hk';

const TENANT_B = '22222222-2222-2222-2222-222222222222';
const SEED_VEHICLE = 'c0000000-0000-0000-0000-000000000003';

const OWNER = { email: 'owner@test.com', password: 'Owner12345!' };
const DRIVER = { email: 'driver@test.com', password: 'Driver12345!' };

const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

function fail(msg, err) {
  console.error(`\n❌ FALLO: ${msg}`);
  if (err) console.error('   ', err.message || err);
  process.exit(1);
}
function ok(msg) {
  console.log(`✓ ${msg}`);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- Esperar a que el stack esté listo ---------------------
async function waitForStack(timeoutMs = 120000) {
  const deadline = Date.now() + timeoutMs;
  let lastErr;
  while (Date.now() < deadline) {
    try {
      const health = await fetch(`${SUPABASE_URL}/auth/v1/health`, {
        headers: { apikey: ANON_KEY },
      });
      if (health.ok) {
        // probar también REST
        const { error } = await admin.from('tenants').select('id').limit(1);
        if (!error) {
          ok('Stack Supabase disponible (auth + rest)');
          return;
        }
        lastErr = error;
      }
    } catch (e) {
      lastErr = e;
    }
    await sleep(2000);
  }
  fail('El stack no estuvo disponible a tiempo', lastErr);
}

// --- Buscar usuario auth por email -------------------------
async function findAuthUserByEmail(email) {
  for (let page = 1; page <= 10; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 });
    if (error) return null;
    const u = data.users.find((x) => x.email === email);
    if (u) return u;
    if (data.users.length < 200) break;
  }
  return null;
}

// --- Provisionar usuario auth y enlazar al perfil ----------
async function provisionUser({ email, password }) {
  let userId;
  const { data, error } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });
  if (error) {
    // probablemente ya existe -> recuperarlo
    const existing = await findAuthUserByEmail(email);
    if (!existing) fail(`No se pudo crear ni encontrar el usuario auth ${email}`, error);
    userId = existing.id;
  } else {
    userId = data.user.id;
  }

  // Re-mapear el id del perfil al id real de auth (FK con ON UPDATE CASCADE).
  const { error: upErr } = await admin
    .from('users')
    .update({ id: userId })
    .eq('email', email);
  if (upErr) fail(`No se pudo enlazar el perfil de ${email} con auth`, upErr);

  return userId;
}

// --- Cliente autenticado -----------------------------------
async function signIn({ email, password }) {
  const client = createClient(SUPABASE_URL, ANON_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data, error } = await client.auth.signInWithPassword({ email, password });
  if (error) fail(`Login fallido para ${email}`, error);
  if (!data.session) fail(`Sin sesión tras login de ${email}`);
  return client;
}

async function main() {
  console.log('=== TaxiCount smoke test ===\n');

  await waitForStack();

  // Bootstrap de usuarios de autenticación
  const ownerId = await provisionUser(OWNER);
  const driverId = await provisionUser(DRIVER);
  ok(`Usuarios provisionados (owner=${ownerId.slice(0, 8)}…, driver=${driverId.slice(0, 8)}…)`);

  // 1) Login owner
  const ownerClient = await signIn(OWNER);
  ok('Login como owner');

  // 2) owner crea un vehículo
  const plate = `TEST-${Date.now().toString().slice(-5)}`;
  const { data: veh, error: vehErr } = await ownerClient
    .from('vehicles')
    .insert({
      tenant_id: '11111111-1111-1111-1111-111111111111',
      license_plate: plate,
      model: 'SEAT León',
    })
    .select()
    .single();
  if (vehErr) fail('owner no pudo crear vehículo', vehErr);
  ok(`owner creó vehículo ${veh.license_plate}`);

  // 3) Login driver
  const driverClient = await signIn(DRIVER);
  ok('Login como driver');

  // 4) driver inserta una transacción
  const amount = 33.33;
  const { data: tx, error: txErr } = await driverClient
    .from('transactions')
    .insert({
      tenant_id: '11111111-1111-1111-1111-111111111111',
      user_id: driverId,
      vehicle_id: SEED_VEHICLE,
      amount,
      category: 'carrera',
      type: 'income',
      payment_method: 'card',
      description: 'Carrera smoke-test',
    })
    .select()
    .single();
  if (txErr) fail('driver no pudo insertar transacción', txErr);
  ok(`driver insertó transacción ${tx.id.slice(0, 8)}…`);

  // 5) owner ve la transacción del driver
  const { data: ownerTx, error: ownerTxErr } = await ownerClient
    .from('transactions')
    .select('*')
    .eq('id', tx.id);
  if (ownerTxErr) fail('owner no pudo leer transacciones', ownerTxErr);
  if (!ownerTx || ownerTx.length !== 1) {
    fail('owner NO ve la transacción del driver (RLS owner-tenant fallida)');
  }
  ok('owner ve la transacción del driver (RLS owner)');

  // 6) Aislamiento: driver NO debe ver transacciones del tenant B
  const { data: leaked, error: leakErr } = await driverClient
    .from('transactions')
    .select('*')
    .eq('tenant_id', TENANT_B);
  if (leakErr) fail('Error consultando aislamiento', leakErr);
  if (leaked && leaked.length > 0) {
    fail(`Fuga de datos: el driver ve ${leaked.length} transacción(es) del tenant B`);
  }
  ok('driver NO ve transacciones de otro tenant (aislamiento RLS)');

  // 7) Aislamiento de escritura: driver no puede insertar en tenant B
  const { error: writeBErr } = await driverClient.from('transactions').insert({
    tenant_id: TENANT_B,
    user_id: driverId,
    amount: 1,
    type: 'income',
  });
  if (!writeBErr) {
    fail('Fuga de escritura: el driver pudo insertar en el tenant B');
  }
  ok('driver NO puede escribir en otro tenant (RLS with check)');

  console.log('\n✅ SMOKE TEST OK — entorno dev validado.');
  process.exit(0);
}

main().catch((err) => fail('Excepción no controlada', err));
