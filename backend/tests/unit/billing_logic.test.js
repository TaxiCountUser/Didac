// Test de LÓGICA de facturación Stripe (puro, SIN red ni stack Supabase).
// Cubre applyStripeEvent y los helpers de mapeo, que son el núcleo crítico de
// pagos. Corre en CI (no necesita docker/supabase). Los tests de integración
// (webhook.test.js / billing_endpoints.test.js) cubren el camino real con el
// stack vivo en local.
import assert from 'node:assert';

process.env.STRIPE_PRICE_SEAT_MONTHLY = 'price_seat_m_test';
process.env.STRIPE_PRICE_SEAT_YEARLY = 'price_seat_y_test';

const { applyStripeEvent, handleStripeEvent, planForPrice, planForPlanId, mapStripeStatus } =
  await import('../../src/billing.js');

// Supabase falso: registra los update() y resuelve tenant por customer en
// select().eq().maybeSingle() (para resolveTenantId).
function makeFakeSupabase({ tenantForCustomer = null } = {}) {
  const updates = [];
  const fake = {
    updates,
    from() {
      return {
        update(payload) {
          return {
            eq(col, val) {
              updates.push({ payload, col, val });
              return Promise.resolve({ data: null, error: null });
            },
          };
        },
        select() {
          return {
            eq() {
              return {
                maybeSingle() {
                  return Promise.resolve({
                    data: tenantForCustomer ? { id: tenantForCustomer } : null,
                    error: null,
                  });
                },
              };
            },
          };
        },
      };
    },
  };
  return fake;
}

let failures = 0;
const check = (name, fn) =>
  Promise.resolve()
    .then(fn)
    .then(() => console.log(`✓ ${name}`))
    .catch((e) => { failures++; console.error(`✗ ${name}:`, e.message); });

async function run() {
  // -------- Helpers puros --------
  await check('planForPrice mapea mensual y anual al plan seat', () => {
    assert.deepStrictEqual(planForPrice('price_seat_m_test'), { plan_id: 'seat', drivers_limit: null });
    assert.deepStrictEqual(planForPrice('price_seat_y_test'), { plan_id: 'seat', drivers_limit: null });
    assert.strictEqual(planForPrice('price_desconocido'), null);
    assert.strictEqual(planForPrice(''), null);
  });

  await check('planForPlanId y mapStripeStatus', () => {
    assert.deepStrictEqual(planForPlanId('seat'), { plan_id: 'seat', drivers_limit: null });
    assert.strictEqual(planForPlanId('inexistente'), null);
    assert.strictEqual(mapStripeStatus('active'), 'active');
    assert.strictEqual(mapStripeStatus('trialing'), 'trialing');
    assert.strictEqual(mapStripeStatus('past_due'), 'past_due');
    assert.strictEqual(mapStripeStatus('unpaid'), 'past_due');
    assert.strictEqual(mapStripeStatus('canceled'), 'canceled');
    assert.strictEqual(mapStripeStatus('incomplete_expired'), 'canceled');
    assert.strictEqual(mapStripeStatus('otra_cosa'), 'inactive');
  });

  // -------- applyStripeEvent --------
  await check('checkout.session.completed -> active + seat + customer/sub', async () => {
    const sb = makeFakeSupabase();
    const r = await applyStripeEvent(sb, {
      type: 'checkout.session.completed',
      data: { object: {
        customer: 'cus_1', subscription: 'sub_1',
        metadata: { tenant_id: 'T1', plan_id: 'seat', drivers_limit: 'null' },
      } },
    });
    assert.strictEqual(r.handled, true);
    assert.strictEqual(r.tenant_id, 'T1');
    assert.strictEqual(sb.updates.length, 1);
    const u = sb.updates[0];
    assert.strictEqual(u.val, 'T1');
    assert.strictEqual(u.payload.subscription_status, 'active');
    assert.strictEqual(u.payload.plan_id, 'seat');
    // drivers_limit (cupo de asientos) ya NO se toca en el webhook: lo fija
    // enforceSeatLimit leyendo la cantidad real de la suscripción de Stripe.
    assert.strictEqual(u.payload.drivers_limit, undefined);
    assert.strictEqual(u.payload.stripe_customer_id, 'cus_1');
    assert.strictEqual(u.payload.stripe_subscription_id, 'sub_1');
  });

  await check('checkout.session.completed sin tenant_id -> no manejado', async () => {
    const sb = makeFakeSupabase();
    const r = await applyStripeEvent(sb, {
      type: 'checkout.session.completed',
      data: { object: { customer: 'cus_x', metadata: {} } },
    });
    assert.strictEqual(r.handled, false);
    assert.strictEqual(sb.updates.length, 0);
  });

  await check('customer.subscription.updated (price seat) -> status + plan', async () => {
    const sb = makeFakeSupabase();
    const r = await applyStripeEvent(sb, {
      type: 'customer.subscription.updated',
      data: { object: {
        customer: 'cus_1', status: 'active',
        metadata: { tenant_id: 'T1' },
        items: { data: [{ price: { id: 'price_seat_m_test' } }] },
      } },
    });
    assert.strictEqual(r.handled, true);
    assert.strictEqual(sb.updates[0].payload.subscription_status, 'active');
    assert.strictEqual(sb.updates[0].payload.plan_id, 'seat');
    // drivers_limit (cupo) ya no se toca aquí; lo gestiona enforceSeatLimit.
    assert.strictEqual(sb.updates[0].payload.drivers_limit, undefined);
  });

  await check('customer.subscription.deleted -> canceled (resuelve por customer)', async () => {
    const sb = makeFakeSupabase({ tenantForCustomer: 'T9' });
    const r = await applyStripeEvent(sb, {
      type: 'customer.subscription.deleted',
      data: { object: { customer: 'cus_9' } },
    });
    assert.strictEqual(r.handled, true);
    assert.strictEqual(r.tenant_id, 'T9');
    assert.strictEqual(sb.updates[0].payload.subscription_status, 'canceled');
  });

  await check('invoice.paid -> active', async () => {
    const sb = makeFakeSupabase({ tenantForCustomer: 'T2' });
    const r = await applyStripeEvent(sb, {
      type: 'invoice.paid', data: { object: { customer: 'cus_2' } },
    });
    assert.strictEqual(r.handled, true);
    assert.strictEqual(sb.updates[0].payload.subscription_status, 'active');
  });

  await check('invoice.payment_failed -> past_due', async () => {
    const sb = makeFakeSupabase({ tenantForCustomer: 'T3' });
    const r = await applyStripeEvent(sb, {
      type: 'invoice.payment_failed', data: { object: { customer: 'cus_3' } },
    });
    assert.strictEqual(r.handled, true);
    assert.strictEqual(sb.updates[0].payload.subscription_status, 'past_due');
  });

  await check('invoice.paid con customer desconocido -> no manejado, sin update', async () => {
    const sb = makeFakeSupabase({ tenantForCustomer: null });
    const r = await applyStripeEvent(sb, {
      type: 'invoice.paid', data: { object: { customer: 'cus_fantasma' } },
    });
    assert.strictEqual(r.handled, false);
    assert.strictEqual(sb.updates.length, 0);
  });

  await check('evento desconocido -> no manejado', async () => {
    const sb = makeFakeSupabase();
    const r = await applyStripeEvent(sb, { type: 'foo.bar', data: { object: {} } });
    assert.strictEqual(r.handled, false);
    assert.strictEqual(sb.updates.length, 0);
  });

  // -------- handleStripeEvent: orquestación (aplica evento + efectos referidos) --------
  // Fake que soporta el update() de applyStripeEvent y el owner lookup encadenado
  // select().eq().eq().maybeSingle().
  function makeOrchestraSupabase(ownerId) {
    return {
      from() {
        return {
          update() { return { eq: () => Promise.resolve({ data: null, error: null }) }; },
          select() {
            const chain = { eq: () => chain, maybeSingle: () =>
              Promise.resolve({ data: ownerId ? { id: ownerId } : null, error: null }) };
            return chain;
          },
        };
      },
    };
  }

  await check('handleStripeEvent: al pagar encola validación y recalcula hitos del owner', async () => {
    const calls = [];
    const deps = {
      enqueueReferralValidation: (t) => { calls.push(['enqueue', t]); },
      recomputeReferrerMilestones: (u) => { calls.push(['recompute', u]); },
      rejectPendingReferralValidation: (t) => { calls.push(['reject', t]); },
      revertReferralForTenant: (t) => { calls.push(['revert', t]); },
    };
    const event = {
      type: 'checkout.session.completed',
      data: { object: { customer: 'cus_x', subscription: 'sub_x',
        metadata: { tenant_id: 'T1', plan_id: 'seat', drivers_limit: 'null' } } },
    };
    const r = await handleStripeEvent(makeOrchestraSupabase('OWNER1'), event, deps);
    assert.strictEqual(r.handled, true);
    assert.strictEqual(r.tenant_id, 'T1');
    assert.deepStrictEqual(calls, [['enqueue', 'T1'], ['recompute', 'OWNER1']]);
  });

  await check('handleStripeEvent: al cancelar rechaza validación y hace clawback', async () => {
    const calls = [];
    const deps = {
      enqueueReferralValidation: (t) => { calls.push(['enqueue', t]); },
      rejectPendingReferralValidation: (t) => { calls.push(['reject', t]); },
      revertReferralForTenant: (t) => { calls.push(['revert', t]); },
    };
    const event = { type: 'customer.subscription.deleted',
      data: { object: { customer: 'cus_x', metadata: { tenant_id: 'T2' } } } };
    const r = await handleStripeEvent(makeOrchestraSupabase(), event, deps);
    assert.strictEqual(r.handled, true);
    assert.deepStrictEqual(calls, [['reject', 'T2'], ['revert', 'T2']]);
  });

  await check('handleStripeEvent: un fallo en los efectos de referidos NO tumba el resultado', async () => {
    const event = {
      type: 'invoice.paid',
      data: { object: { customer: 'cus_x' } },
    };
    // resolveTenantId usa select().eq().maybeSingle(); el owner lookup, dos eq().
    const r = await handleStripeEvent(makeOrchestraSupabase('OWNER1'), event, {
      enqueueReferralValidation: () => { throw new Error('boom'); },
      log: { error() {} },
    });
    assert.strictEqual(r.handled, true); // el cobro se aplicó pese al fallo del efecto
  });

  if (failures > 0) {
    console.error(`\n${failures} test(s) de lógica de billing fallaron.`);
    process.exit(1);
  }
  console.log('\nbilling_logic.test.js OK');
  process.exit(0);
}

run().catch((e) => { console.error('Error inesperado en billing_logic.test.js:', e); process.exit(1); });
