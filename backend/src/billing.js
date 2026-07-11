// ============================================================
// TaxiCount - Fase 4: lógica de facturación (Stripe).
// Mapa de planes y procesamiento de eventos de webhook. Se mantiene
// separado de server.js para poder testearlo de forma aislada.
// ============================================================

// Modelo de precios POR ASIENTO (por conductor), escalonado por volumen en Stripe.
// Un único "plan" (seat) con dos Price IDs (mensual/anual). La cantidad del
// item = nº de conductores; Stripe aplica los tramos por volumen:
//   1–75 conductores -> 2 €/mes (15,6 €/año) por conductor
//   76+ (ilimitado)  -> tarifa plana 150 €/mes (1170 €/año)
// drivers_limit = null porque NO hay tope: añadir conductores solo sube la factura.
export const SEAT_TIER_LIMIT = 75; // último tramo por asiento (informativo)

export function plans() {
  return {
    seat: {
      plan_id: 'seat', drivers_limit: null,
      priceId: process.env.STRIPE_PRICE_SEAT_MONTHLY || '',
      priceIdYearly: process.env.STRIPE_PRICE_SEAT_YEARLY || '',
    },
  };
}

/** Devuelve {plan_id, drivers_limit} a partir de un Price ID (mensual o anual), o null. */
export function planForPrice(priceId) {
  if (!priceId) return null;
  const p = plans().seat;
  if (priceId === p.priceId || priceId === p.priceIdYearly) {
    return { plan_id: 'seat', drivers_limit: null };
  }
  return null;
}

/** Devuelve {plan_id, drivers_limit} a partir de un plan_id ('seat'), o null. */
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

/**
 * Efectos de referidos de un evento ya aplicado. Las funciones que tocan datos
 * (colas, hitos) se INYECTAN vía `deps` porque en server.js son closures sobre
 * supabase; así esta lógica queda testeable de forma aislada.
 * - al PAGAR (checkout/invoice.paid): encola validación a +15 días y, si el
 *   tenant es un referidor con hitos diferidos, se los recalcula.
 * - al CANCELAR (subscription.deleted): rechaza la validación pendiente y
 *   revierte (clawback) los días ya concedidos.
 */
async function applyReferralSideEffects(supabase, result, deps = {}) {
  const {
    enqueueReferralValidation, recomputeReferrerMilestones,
    rejectPendingReferralValidation, revertReferralForTenant,
  } = deps;
  const tenantId = result.tenant_id;
  if (!tenantId) return;

  if (result.type === 'checkout.session.completed' || result.type === 'invoice.paid') {
    if (enqueueReferralValidation) await enqueueReferralValidation(tenantId);
    const { data: owner } = await supabase.from('users')
      .select('id').eq('tenant_id', tenantId).eq('role', 'owner').maybeSingle();
    if (owner?.id && recomputeReferrerMilestones) await recomputeReferrerMilestones(owner.id);
  } else if (result.type === 'customer.subscription.deleted') {
    if (rejectPendingReferralValidation) await rejectPendingReferralValidation(tenantId);
    if (revertReferralForTenant) await revertReferralForTenant(tenantId);
  }
}

/**
 * Orquesta un evento de Stripe: aplica el cambio en `tenants` (applyStripeEvent)
 * y ejecuta los efectos de referidos. Es el punto de entrada ÚNICO del dominio
 * de billing; el handler HTTP solo se ocupa de firma, idempotencia y ACK.
 * Los efectos de referidos NUNCA tumban el resultado (best-effort con log).
 * @returns {Promise<{handled:boolean, type:string, tenant_id?:string|null}>}
 */
export async function handleStripeEvent(supabase, event, deps = {}) {
  const result = await applyStripeEvent(supabase, event);
  if (result.handled && result.tenant_id) {
    try {
      await applyReferralSideEffects(supabase, result, deps);
    } catch (e) {
      deps.log?.error?.(`[referral] ${e.message}`);
    }
  }
  return result;
}
