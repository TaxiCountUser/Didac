// Test del webhook de Stripe: firma real (sin red) + actualización en la BD.
// Requiere el stack local arriba (db/kong) para el cliente service_role.
import assert from 'node:assert';
import { randomUUID } from 'node:crypto';
import Stripe from 'stripe';

process.env.NODE_ENV = 'test';
process.env.STRIPE_SECRET_KEY = process.env.STRIPE_SECRET_KEY || 'sk_test_dummy';
process.env.STRIPE_WEBHOOK_SECRET = 'whsec_test_secret_for_signing_payloads';
process.env.STRIPE_PRICE_SEAT_MONTHLY = 'price_seat_m_test';
process.env.STRIPE_PRICE_SEAT_YEARLY = 'price_seat_y_test';
process.env.CRON_SECRET = process.env.CRON_SECRET || 'cron_secret_test';
// Backend contra el stack local (host -> kong en 54321).
process.env.SUPABASE_URL = process.env.SUPABASE_URL || 'http://localhost:54321';
process.env.SUPABASE_SERVICE_ROLE_KEY =
  process.env.SUPABASE_SERVICE_ROLE_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UtZGVtbyIsImlhdCI6MTcwMDAwMDAwMCwiZXhwIjoyMDAwMDAwMDAwfQ.8T3kmJ5SaqY3bVmU02ZJ4MIoHe5z7R4qQ4T9VqJA8hk';

const { buildApp } = await import('../../src/server.js');
const { stackReachable, skipNoStack } = await import('./_stack.js');

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);
const WHSEC = process.env.STRIPE_WEBHOOK_SECRET;

let failures = 0;
function check(name, fn) {
  return fn()
    .then(() => console.log(`✓ ${name}`))
    .catch((e) => {
      failures++;
      console.error(`✗ ${name}:`, e.message);
    });
}

function signed(eventObj) {
  const payload = JSON.stringify(eventObj);
  const header = stripe.webhooks.generateTestHeaderString({ payload, secret: WHSEC });
  return { payload, header };
}

async function post(app, eventObj, sigHeader) {
  const { payload, header } = sigHeader ? { payload: JSON.stringify(eventObj), header: sigHeader } : signed(eventObj);
  return app.inject({
    method: 'POST',
    url: '/webhooks/stripe',
    headers: { 'content-type': 'application/json', 'stripe-signature': header },
    payload,
  });
}

async function run() {
  const app = await buildApp();
  const sb = app.supabase;
  assert.ok(sb, 'el cliente service_role debe estar configurado (stack local arriba)');
  if (!(await stackReachable(sb))) return skipNoStack('webhook.test.js', app);

  const tenantId = randomUUID();
  const customerId = `cus_test_${Date.now()}`;
  // Prefijo único por ejecución para los event_id: hace el test repetible aunque
  // la tabla webhook_events (idempotencia) persista entre runs en un stack local.
  const EV = `evt_${Date.now()}_`;
  await sb.from('tenants').insert({ id: tenantId, name: 'Webhook Test Tenant' });

  // 1) checkout.session.completed -> active + plan seat (ilimitado) + customer
  await check('checkout.session.completed activa la suscripción por asiento', async () => {
    const event = {
      id: EV + '1',
      type: 'checkout.session.completed',
      data: {
        object: {
          id: 'cs_1',
          customer: customerId,
          subscription: 'sub_test_1',
          metadata: { tenant_id: tenantId, plan_id: 'seat', drivers_limit: 'null' },
        },
      },
    };
    const res = await post(app, event);
    assert.strictEqual(res.statusCode, 200, `status ${res.statusCode}: ${res.body}`);
    assert.strictEqual(res.json().received, true);
    const { data } = await sb.from('tenants').select('*').eq('id', tenantId).single();
    assert.strictEqual(data.subscription_status, 'active');
    assert.strictEqual(data.plan_id, 'seat');
    assert.strictEqual(data.drivers_limit, null);
    assert.strictEqual(data.stripe_customer_id, customerId);
    assert.strictEqual(data.stripe_subscription_id, 'sub_test_1');
  });

  // 1-bis) IDEMPOTENCIA: reenviar el MISMO evento (mismo event_id) no reprocesa.
  await check('evento duplicado se ignora (idempotencia)', async () => {
    // Ensuciamos el tenant a mano; si el duplicado se procesara, lo "arreglaría".
    await sb.from('tenants').update({ subscription_status: 'canceled' }).eq('id', tenantId);
    const event = {
      id: EV + '1', // mismo id que el test 1 (ya 'processed')
      type: 'checkout.session.completed',
      data: {
        object: {
          id: 'cs_1', customer: customerId, subscription: 'sub_test_1',
          metadata: { tenant_id: tenantId, plan_id: 'seat', drivers_limit: 'null' },
        },
      },
    };
    const res = await post(app, event);
    assert.strictEqual(res.statusCode, 200, `status ${res.statusCode}: ${res.body}`);
    assert.strictEqual(res.json().duplicate, true, 'debe marcarse como duplicado');
    const { data } = await sb.from('tenants').select('subscription_status').eq('id', tenantId).single();
    assert.strictEqual(data.subscription_status, 'canceled', 'el duplicado NO debe reprocesar');
    // Restaura el estado para no afectar a otros asertos.
    await sb.from('tenants').update({ subscription_status: 'active' }).eq('id', tenantId);
  });

  // 2) invoice.payment_failed -> past_due (resuelve tenant por customer)
  await check('invoice.payment_failed marca past_due', async () => {
    const event = {
      id: EV + '2',
      type: 'invoice.payment_failed',
      data: { object: { id: 'in_1', customer: customerId } },
    };
    const res = await post(app, event);
    assert.strictEqual(res.statusCode, 200, `status ${res.statusCode}: ${res.body}`);
    const { data } = await sb.from('tenants').select('subscription_status').eq('id', tenantId).single();
    assert.strictEqual(data.subscription_status, 'past_due');
  });

  // 3) invoice.paid -> active de nuevo
  await check('invoice.paid reactiva la suscripción', async () => {
    const event = { id: EV + '3', type: 'invoice.paid', data: { object: { id: 'in_2', customer: customerId } } };
    const res = await post(app, event);
    assert.strictEqual(res.statusCode, 200);
    const { data } = await sb.from('tenants').select('subscription_status').eq('id', tenantId).single();
    assert.strictEqual(data.subscription_status, 'active');
  });

  // 4) customer.subscription.updated con price de asiento -> plan seat (ilimitado)
  await check('customer.subscription.updated mantiene el plan por asiento', async () => {
    const event = {
      id: EV + '4',
      type: 'customer.subscription.updated',
      data: {
        object: {
          id: 'sub_test_1',
          customer: customerId,
          status: 'active',
          items: { data: [{ price: { id: 'price_seat_m_test' } }] },
        },
      },
    };
    const res = await post(app, event);
    assert.strictEqual(res.statusCode, 200);
    const { data } = await sb.from('tenants').select('plan_id, drivers_limit').eq('id', tenantId).single();
    assert.strictEqual(data.plan_id, 'seat');
    assert.strictEqual(data.drivers_limit, null);
  });

  // 5) customer.subscription.deleted -> canceled
  await check('customer.subscription.deleted cancela', async () => {
    const event = {
      id: EV + '5',
      type: 'customer.subscription.deleted',
      data: { object: { id: 'sub_test_1', customer: customerId } },
    };
    const res = await post(app, event);
    assert.strictEqual(res.statusCode, 200);
    const { data } = await sb.from('tenants').select('subscription_status').eq('id', tenantId).single();
    assert.strictEqual(data.subscription_status, 'canceled');
  });

  // 5-bis) REPROCESO (M2-6): un evento que quedó en 'error' se reintenta desde la
  // bandeja y, si aplica bien, pasa a 'processed' y actualiza el tenant.
  await check('retry-webhooks reprocesa un evento en error', async () => {
    // Tras el test 5 el tenant está 'canceled'. Sembramos un invoice.paid fallido:
    // al reprocesarlo debe reactivar (active) y marcar el evento 'processed'.
    const retryId = EV + 'retry';
    await sb.from('webhook_events').insert({
      event_id: retryId, type: 'invoice.paid', status: 'error', attempts: 1,
      payload: { id: retryId, type: 'invoice.paid', data: { object: { id: 'in_retry', customer: customerId } } },
    });
    const res = await app.inject({
      method: 'POST', url: '/api/v1/admin/cron/retry-webhooks',
      headers: { 'x-cron-secret': process.env.CRON_SECRET },
    });
    assert.strictEqual(res.statusCode, 200, `status ${res.statusCode}: ${res.body}`);
    assert.ok(res.json().recovered >= 1, 'debe recuperar al menos un evento');
    const { data: ev } = await sb.from('webhook_events').select('status').eq('event_id', retryId).single();
    assert.strictEqual(ev.status, 'processed', 'el evento reprocesado debe quedar processed');
    const { data } = await sb.from('tenants').select('subscription_status').eq('id', tenantId).single();
    assert.strictEqual(data.subscription_status, 'active', 'el reproceso debe reactivar el tenant');
    await sb.from('webhook_events').delete().eq('event_id', retryId);
  });

  // 6) Firma inválida -> 400
  await check('firma inválida devuelve 400', async () => {
    const event = { id: EV + '6', type: 'invoice.paid', data: { object: { customer: customerId } } };
    const res = await post(app, event, 't=1,v1=deadbeef');
    assert.strictEqual(res.statusCode, 400, `status ${res.statusCode}`);
  });

  // Limpieza
  await sb.from('tenants').delete().eq('id', tenantId);
  await app.close();

  if (failures > 0) {
    console.error(`\n${failures} test(s) de webhook fallaron.`);
    process.exit(1);
  }
  console.log('\nTests de webhook OK.');
  process.exit(0);
}

run().catch((e) => {
  console.error('Error inesperado en webhook.test.js:', e);
  process.exit(1);
});
