// ============================================================
// TaxiCount - Fase 4: lógica de facturación (Stripe).
// Mapa de planes y procesamiento de eventos de webhook. Se mantiene
// separado de server.js para poder testearlo de forma aislada.
// ============================================================

// Definición de planes. El límite de conductores por plan:
//   Starter -> 2 | Pro -> 10 | Business -> ilimitado (null)
// Los Price IDs vienen de variables de entorno (modo test).
export function plans() {
  return {
    starter: { plan_id: 'starter', drivers_limit: 2, priceId: process.env.STRIPE_PRICE_STARTER || '' },
    pro: { plan_id: 'pro', drivers_limit: 10, priceId: process.env.STRIPE_PRICE_PRO || '' },
    business: { plan_id: 'business', drivers_limit: null, priceId: process.env.STRIPE_PRICE_BUSINESS || '' },
  };
}

/** Devuelve {plan_id, drivers_limit} a partir de un Price ID, o null. */
export function planForPrice(priceId) {
  if (!priceId) return null;
  const found = Object.values(plans()).find((p) => p.priceId && p.priceId === priceId);
  return found ? { plan_id: found.plan_id, drivers_limit: found.drivers_limit } : null;
}

/** Devuelve {plan_id, drivers_limit} a partir de un plan_id ('starter'…), o null. */
export function planForPlanId(planId) {
  if (!planId) return null;
  const p = plans()[planId];
  return p ? { plan_id: p.plan_id, drivers_limit: p.drivers_limit } : null;
}

/** Normaliza el `status` de Stripe a nuestro vocabulario interno. */
export function mapStripeStatus(status) {
  switch (status) {
    case 'active':
      return 'active';
    case 'trialing':
      return 'trialing';
    case 'past_due':
    case 'unpaid':
      return 'past_due';
    case 'canceled':
    case 'incomplete_expired':
      return 'canceled';
    default:
      return 'inactive';
  }
}

// Resuelve el tenant a partir del customer de Stripe (o de la metadata).
async function resolveTenantId(supabase, { customerId, metadataTenantId }) {
  if (metadataTenantId) return metadataTenantId;
  if (!customerId) return null;
  const { data } = await supabase
    .from('tenants')
    .select('id')
    .eq('stripe_customer_id', customerId)
    .maybeSingle();
  return data?.id ?? null;
}

/**
 * Aplica un evento de Stripe a la tabla `tenants`.
 * @returns {Promise<{handled:boolean, type:string, tenant_id?:string|null}>}
 */
export async function applyStripeEvent(supabase, event) {
  const type = event?.type;
  const obj = event?.data?.object ?? {};

  switch (type) {
    case 'checkout.session.completed': {
      const tenantId = obj.metadata?.tenant_id ?? null;
      if (!tenantId) return { handled: false, type, tenant_id: null };
      // Plan: por metadata (lo fijamos al crear la sesión) o por price.
      const plan =
        planForPlanId(obj.metadata?.plan_id) ||
        (obj.metadata?.drivers_limit !== undefined
          ? { plan_id: obj.metadata?.plan_id ?? null, drivers_limit: parseLimit(obj.metadata?.drivers_limit) }
          : null);
      const update = {
        stripe_customer_id: obj.customer ?? null,
        stripe_subscription_id: obj.subscription ?? null,
        subscription_status: 'active',
      };
      if (plan) {
        update.plan_id = plan.plan_id;
        update.drivers_limit = plan.drivers_limit;
      }
      await supabase.from('tenants').update(update).eq('id', tenantId);
      return { handled: true, type, tenant_id: tenantId };
    }

    case 'customer.subscription.updated': {
      const tenantId = await resolveTenantId(supabase, {
        customerId: obj.customer,
        metadataTenantId: obj.metadata?.tenant_id,
      });
      if (!tenantId) return { handled: false, type, tenant_id: null };
      const priceId = obj.items?.data?.[0]?.price?.id;
      const plan = planForPrice(priceId);
      const update = { subscription_status: mapStripeStatus(obj.status) };
      if (plan) {
        update.plan_id = plan.plan_id;
        update.drivers_limit = plan.drivers_limit;
      }
      await supabase.from('tenants').update(update).eq('id', tenantId);
      return { handled: true, type, tenant_id: tenantId };
    }

    case 'customer.subscription.deleted': {
      const tenantId = await resolveTenantId(supabase, {
        customerId: obj.customer,
        metadataTenantId: obj.metadata?.tenant_id,
      });
      if (!tenantId) return { handled: false, type, tenant_id: null };
      await supabase.from('tenants').update({ subscription_status: 'canceled' }).eq('id', tenantId);
      return { handled: true, type, tenant_id: tenantId };
    }

    case 'invoice.paid': {
      const tenantId = await resolveTenantId(supabase, { customerId: obj.customer });
      if (!tenantId) return { handled: false, type, tenant_id: null };
      await supabase.from('tenants').update({ subscription_status: 'active' }).eq('id', tenantId);
      return { handled: true, type, tenant_id: tenantId };
    }

    case 'invoice.payment_failed': {
      const tenantId = await resolveTenantId(supabase, { customerId: obj.customer });
      if (!tenantId) return { handled: false, type, tenant_id: null };
      await supabase.from('tenants').update({ subscription_status: 'past_due' }).eq('id', tenantId);
      return { handled: true, type, tenant_id: tenantId };
    }

    default:
      return { handled: false, type: type ?? 'unknown', tenant_id: null };
  }
}

function parseLimit(v) {
  if (v === null || v === undefined || v === '' || v === 'null') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}
