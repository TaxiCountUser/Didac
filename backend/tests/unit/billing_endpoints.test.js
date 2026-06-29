// Test de los endpoints de Checkout y Portal con un cliente Stripe MOCK
// (sin red). Usa un Owner real del stack local para el JWT.
import assert from 'node:assert';
import { createClient } from '@supabase/supabase-js';

process.env.NODE_ENV = 'test';
process.env.STRIPE_PRICE_SEAT_MONTHLY = 'price_seat_m_test';
process.env.STRIPE_PRICE_SEAT_YEARLY = 'price_seat_y_test';
process.env.SUPABASE_URL = process.env.SUPABASE_URL || 'http://localhost:54321';
process.env.SUPABASE_SERVICE_ROLE_KEY =
  process.env.SUPABASE_SERVICE_ROLE_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UtZGVtbyIsImlhdCI6MTcwMDAwMDAwMCwiZXhwIjoyMDAwMDAwMDAwfQ.8T3kmJ5SaqY3bVmU02ZJ4MIoHe5z7R4qQ4T9VqJA8hk';
const ANON =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlLWRlbW8iLCJpYXQiOjE3MDAwMDAwMDAsImV4cCI6MjAwMDAwMDAwMH0.ZxBhVEYye2lqm5NDdkey-JP6uTHcqvZriXUoBtyQniY';

const { buildApp } = await import('../../src/server.js');

// Stripe mock: registra las llamadas y devuelve URLs sintéticas.
const calls = [];
const stripeMock = {
  checkout: {
    sessions: {
      create: async (args) => {
        calls.push(['checkout', args]);
        return { id: 'cs_test_123', url: 'https://stripe.test/checkout/cs_test_123' };
      },
    },
  },
  billingPortal: {
    sessions: {
      create: async (args) => {
        calls.push(['portal', args]);
        return { id: 'bps_test_123', url: 'https://stripe.test/portal/bps_test_123' };
      },
    },
  },
};

let failures = 0;
const check = (name, fn) =>
  fn()
    .then(() => console.log(`✓ ${name}`))
    .catch((e) => {
      failures++;
      console.error(`✗ ${name}:`, e.message);
    });

async function run() {
  const app = await buildApp({ stripe: stripeMock });
  const sb = app.supabase;
  assert.ok(sb, 'service_role configurado (stack local arriba)');

  // Crea un Owner real (el trigger crea tenant + perfil owner).
  const anon = createClient(process.env.SUPABASE_URL, ANON, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const email = `bill.owner.${Date.now()}@test.com`;
  const { data: su, error } = await anon.auth.signUp({
    email,
    password: 'Owner12345!',
    options: { data: { company_name: 'Flota Billing' } },
  });
  assert.ok(!error, `signUp owner: ${error?.message}`);
  const token = su.session.access_token;
  const ownerId = su.user.id;
  const { data: prof } = await sb.from('users').select('tenant_id').eq('id', ownerId).single();
  const tenantId = prof.tenant_id;

  await check('create-checkout-session devuelve URL', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/api/v1/create-checkout-session',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      payload: { priceId: 'price_seat_m_test' },
    });
    assert.strictEqual(res.statusCode, 200, `status ${res.statusCode}: ${res.body}`);
    const body = res.json();
    assert.ok(body.url.startsWith('https://stripe.test/checkout'), 'devuelve url de checkout');
    const [, args] = calls.find((c) => c[0] === 'checkout');
    assert.strictEqual(args.mode, 'subscription');
    assert.strictEqual(args.metadata.tenant_id, tenantId);
    assert.strictEqual(args.metadata.plan_id, 'seat');
    assert.strictEqual(args.metadata.drivers_limit, 'null');
  });

  await check('create-checkout-session rechaza priceId desconocido (400)', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/api/v1/create-checkout-session',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      payload: { priceId: 'price_inexistente' },
    });
    assert.strictEqual(res.statusCode, 400, `status ${res.statusCode}`);
  });

  await check('create-portal-session sin cliente Stripe -> 400', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/api/v1/create-portal-session',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      payload: {},
    });
    assert.strictEqual(res.statusCode, 400, `status ${res.statusCode}`);
  });

  await check('create-portal-session con cliente Stripe -> URL', async () => {
    await sb.from('tenants').update({ stripe_customer_id: 'cus_billing_test' }).eq('id', tenantId);
    const res = await app.inject({
      method: 'POST',
      url: '/api/v1/create-portal-session',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      payload: {},
    });
    assert.strictEqual(res.statusCode, 200, `status ${res.statusCode}: ${res.body}`);
    assert.ok(res.json().url.startsWith('https://stripe.test/portal'));
    const [, args] = calls.find((c) => c[0] === 'portal');
    assert.strictEqual(args.customer, 'cus_billing_test');
  });

  // Limpieza
  try {
    await sb.auth.admin.deleteUser(ownerId);
  } catch {}
  await app.close();

  if (failures > 0) {
    console.error(`\n${failures} test(s) de endpoints de billing fallaron.`);
    process.exit(1);
  }
  console.log('\nTests de endpoints de billing OK.');
  process.exit(0);
}

run().catch((e) => {
  console.error('Error inesperado en billing_endpoints.test.js:', e);
  process.exit(1);
});
