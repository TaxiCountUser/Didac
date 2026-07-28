// ============================================================
// TaxiCount - Recompensas (crédito Stripe). Fase A del troceig de server.js.
// Modelo: la recompensa se aplica como SALDO NEGATIVO en Stripe (se consume en
// la próxima factura), valorada a la tarifa BASE por asiento del último pago
// (independiente de cupones). La comparten Retos y Referidos.
//
// Helper PURO extraído sin cambio de comportamiento: factory
// createRewards(deps) que devuelve las funciones como closures sobre las deps
// inyectadas. Deps del closure buildApp() que aún viven en server.js y se
// inyectan: tenantIsPaying, refConfig, milestonesFrom, notifyUser (+ stripe,
// supabase, log).
// ============================================================

export function createRewards({
  stripe, supabase, log,
  tenantIsPaying, refConfig, milestonesFrom, notifyUser,
}) {
  // Tarifa EFECTIVA por asiento del último pago, normalizada a MES. Cada tenant
  // usa el suyo (Stripe mantiene el precio hasta migrar la suscripción; los nuevos
  // cogen el nuevo). Devuelve { perSeatCents, seats }.
  async function seatBaseRate(subscriptionId) {
    if (!stripe || !subscriptionId) return { perSeatCents: 0, seats: 0 };
    try {
      const sub = await stripe.subscriptions.retrieve(subscriptionId, { expand: ['items.data.price'] });
      const item = sub.items?.data?.[0];
      if (!item) return { perSeatCents: 0, seats: 0 };
      const price = item.price ?? {};
      const plan = item.plan ?? {}; // estructura legada
      const interval = price.recurring?.interval || plan.interval;
      // unit_amount es el precio de lista ANTES de cupones (los cupones se aplican
      // como discount sobre el total, no tocan unit_amount) -> base sin descuento.
      let unit = price.unit_amount;
      if (unit == null && price.unit_amount_decimal != null) unit = Math.round(Number(price.unit_amount_decimal));
      if (unit == null && plan.amount != null) unit = plan.amount;
      if (unit == null || Number.isNaN(unit)) unit = interval === 'year' ? 3000 : 300; // fallback
      const perSeatCents = interval === 'year' ? Math.round(unit / 12) : unit;
      const seats = (sub.items?.data ?? []).reduce((s, it) => s + (it.quantity ?? 0), 0);
      return { perSeatCents, seats };
    } catch (e) {
      log.warn(`[reward] seatBaseRate ${subscriptionId}: ${e.message}`);
      return { perSeatCents: 0, seats: 0 };
    }
  }

  // Crédito de recompensa: aplica un saldo NEGATIVO al cliente en Stripe, que se
  // consume automáticamente en su PRÓXIMA factura. Devuelve el id de la transacción
  // (para poder revertirla en un clawback) o null si no se aplicó.
  async function applyRewardCredit(customerId, cents, description) {
    if (!stripe || !customerId || !(cents > 0)) return null;
    try {
      const txn = await stripe.customers.createBalanceTransaction(customerId, {
        amount: -Math.round(cents), currency: 'eur', description,
      });
      return txn.id;
    } catch (e) {
      log.warn(`[reward] applyRewardCredit ${customerId}: ${e.message}`);
      return null;
    }
  }

  // Clawback (opción b): retira el crédito que AÚN NO se haya consumido; si ya se
  // gastó (el saldo del cliente ya no lo cubre), se asume la pérdida y NO se cobra
  // de más al cliente. Nunca deja el saldo en positivo (nunca genera un cargo).
  async function reverseRewardCredit(customerId, cents) {
    if (!stripe || !customerId || !(cents > 0)) return 0;
    try {
      const cust = await stripe.customers.retrieve(customerId);
      const bal = cust?.balance ?? 0; // negativo = crédito disponible
      const reverse = Math.min(Math.round(cents), Math.max(0, -bal));
      if (reverse <= 0) return 0;
      await stripe.customers.createBalanceTransaction(customerId, {
        amount: reverse, currency: 'eur', description: 'Clawback recompensa referido',
      });
      return reverse;
    } catch (e) {
      log.warn(`[reward] reverseRewardCredit ${customerId}: ${e.message}`);
      return 0;
    }
  }

  async function applyPendingChallengeCredits(onlyTenantId = null) {
    let cq = supabase
      .from('challenge_claims')
      .select('id, tenant_id, user_id, challenge')
      .eq('status', 'rewarded')
      .is('reward_redeemed_at', null)
      .limit(1000);
    if (onlyTenantId) cq = cq.eq('tenant_id', onlyTenantId);
    const { data: claims } = await cq;
    let rewarded = 0;
    let deferred = 0;
    let skipped = 0;
    for (const c of claims ?? []) {
      // Solo se premia si la empresa ya es de PAGO. En prueba se deja pendiente
      // (sin marcar canjeado) y el cron lo aplicará cuando pase a suscripción.
      if (!(await tenantIsPaying(c.tenant_id))) { deferred++; continue; }
      // Recompensa del reto = 1 ASIENTO · 1 MES, valorado a la tarifa EFECTIVA por
      // asiento del último pago (neto de cupón). Con asientos a precios distintos se
      // usa el asiento MEDIO: coste_mensual_flota / asientos. Se aplica como crédito
      // Stripe que se consume en la PRÓXIMA factura (no extiende trial_ends_at).
      const { data: tRow } = await supabase.from('tenants')
        .select('stripe_customer_id, stripe_subscription_id').eq('id', c.tenant_id).maybeSingle();
      // Reto = 1 asiento · 1 mes a PRECIO BASE (independiente de cupones).
      const { perSeatCents } = await seatBaseRate(tRow?.stripe_subscription_id);
      const creditCents = perSeatCents;
      try {
        const now = new Date();
        const txnId = creditCents > 0
          ? await applyRewardCredit(tRow?.stripe_customer_id, creditCents, `Reto completado (${c.challenge ?? ''})`)
          : null;
        await supabase.from('subscription_extensions').insert({
          user_id: c.user_id, tenant_id: c.tenant_id, extension_type: 'challenge',
          source_id: c.id, days_extended: 0, credit_cents: creditCents, stripe_txn_id: txnId,
          monthly_value: (creditCents / 100).toFixed(2), extended_until: now.toISOString(),
        });
        await supabase.from('challenge_claims')
          .update({ reward_redeemed_at: now.toISOString() }).eq('id', c.id);
        rewarded++;
      } catch (e) {
        log.warn(`[challenge-reward] claim ${c.id}: ${e.message}`);
        skipped++;
      }
    }
    return { rewarded, deferred, skipped };
  }

  // Días gratis conseguidos por un tenant: por RETOS (subscription_extensions
  // type=challenge) y por REFERIDOS (referral_milestone_rewards de sus owners).
  // Es el "ahorro" real del nuevo modelo, medido en días de suscripción gratis.
  async function freeDaysForTenant(tenantId) {
    const { data: exts } = await supabase.from('subscription_extensions')
      .select('days_extended, credit_cents').eq('tenant_id', tenantId).eq('extension_type', 'challenge');
    const challenges = (exts ?? []).reduce((s, r) => s + (r.days_extended ?? 0), 0);
    const challengesCents = (exts ?? []).reduce((s, r) => s + (r.credit_cents ?? 0), 0);
    const { data: owners } = await supabase.from('users')
      .select('id').eq('tenant_id', tenantId).eq('role', 'owner');
    const ownerIds = (owners ?? []).map((o) => o.id);
    let referrals = 0;
    let referralsCents = 0;
    if (ownerIds.length) {
      const { data: rr } = await supabase.from('referral_milestone_rewards')
        .select('days_awarded, credit_cents').in('user_id', ownerIds);
      referrals = (rr ?? []).reduce((s, r) => s + (r.days_awarded ?? 0), 0);
      referralsCents = (rr ?? []).reduce((s, r) => s + (r.credit_cents ?? 0), 0);
    }
    return {
      challenges, referrals, total: challenges + referrals,
      challenges_cents: challengesCents, referrals_cents: referralsCents,
      total_cents: challengesCents + referralsCents,
    };
  }

  // Recalcula los hitos del referidor: concede los nuevos y revoca los que ya no
  // correspondan, respetando el tope anual de días.
  async function recomputeReferrerMilestones(referrerUserId) {
    if (!referrerUserId) return;
    const cfg = await refConfig();
    const milestones = milestonesFrom(cfg);
    const annualMax = parseInt(cfg.referral_annual_max_days ?? '360', 10);
    const year = new Date().getFullYear();

    const { count } = await supabase.from('referrals')
      .select('id', { count: 'exact', head: true })
      .eq('referrer_user_id', referrerUserId).eq('status', 'valid');
    const valid = count ?? 0;

    const { data: u } = await supabase.from('users')
      .select('referral_rewards_annual_days, referral_annual_year').eq('id', referrerUserId).maybeSingle();
    let annualDays = (u?.referral_annual_year === year) ? (u?.referral_rewards_annual_days ?? 0) : 0;

    const { data: claimedRows } = await supabase.from('referral_milestone_rewards')
      .select('id, milestone_level, days_awarded, credit_cents').eq('user_id', referrerUserId);
    const claimed = new Map((claimedRows ?? []).map((r) => [r.milestone_level, r]));
    const target = new Set(milestones.filter((m) => valid >= m.required).map((m) => m.level));

    // El premio solo se aplica si el referidor ya es cliente DE PAGO. En prueba se
    // difiere: al pasar a suscripción (webhook) se recalcula y se conceden los hitos
    // pendientes. Se aplica como CRÉDITO Stripe = N días de la FLOTA a la tarifa
    // efectiva del último pago, consumible en su próxima factura (no toca trial).
    const { data: refUser } = await supabase.from('users')
      .select('tenant_id').eq('id', referrerUserId).maybeSingle();
    const paying = refUser?.tenant_id ? await tenantIsPaying(refUser.tenant_id) : false;
    const { data: refTenant } = refUser?.tenant_id
      ? await supabase.from('tenants').select('stripe_customer_id, stripe_subscription_id').eq('id', refUser.tenant_id).maybeSingle()
      : { data: null };
    const customerId = refTenant?.stripe_customer_id ?? null;
    // Referido = N días de la FLOTA = precio BASE/asiento × asientos × N/30.
    const refRate = paying ? await seatBaseRate(refTenant?.stripe_subscription_id) : { perSeatCents: 0, seats: 0 };
    const fleetM = refRate.perSeatCents * refRate.seats;

    // Conceder hitos alcanzados que aún no se hayan concedido (solo si de pago).
    for (const m of milestones) {
      if (target.has(m.level) && !claimed.has(m.level) && paying) {
        const remaining = Math.max(0, annualMax - annualDays);
        const award = Math.min(m.days, remaining);
        const creditCents = Math.round(fleetM * award / 30);
        const txnId = creditCents > 0
          ? await applyRewardCredit(customerId, creditCents, `Referidos: hito ${m.level} (+${award} dias de flota)`)
          : null;
        await supabase.from('referral_milestone_rewards').insert({
          user_id: referrerUserId, milestone_level: m.level, required: m.required,
          days_awarded: award, credit_cents: creditCents, stripe_txn_id: txnId,
        });
        if (award > 0) {
          annualDays += award;
          await notifyUser(referrerUserId, 'referral_discount',
            { level: m.level, eur: (creditCents / 100).toFixed(2) },
            { type: 'referral_milestone', level: m.level });
        }
        log.info(`[referral] hito ${m.level} concedido a ${referrerUserId} (+${award} días, ${creditCents}c)`);
      }
    }
    // Revocar hitos que ya no correspondan (tras una reversión) — clawback (b):
    // se retira el crédito NO consumido; si ya se gastó, se asume (no se cobra más).
    for (const [lvl, row] of claimed) {
      if (!target.has(lvl)) {
        if ((row.credit_cents ?? 0) > 0 && customerId) await reverseRewardCredit(customerId, row.credit_cents);
        if ((row.days_awarded ?? 0) > 0) annualDays -= row.days_awarded;
        await supabase.from('referral_milestone_rewards').delete().eq('id', row.id);
        log.info(`[referral] hito ${lvl} revocado a ${referrerUserId}`);
      }
    }
    if (annualDays < 0) annualDays = 0;
    const lastLevel = target.size ? Math.max(...target) : 0;
    await supabase.from('users').update({
      referral_total_valid: valid,
      referral_last_milestone_reached: lastLevel,
      referral_rewards_annual_days: annualDays,
      referral_annual_year: year,
    }).eq('id', referrerUserId);
  }

  return {
    seatBaseRate, applyRewardCredit, reverseRewardCredit,
    applyPendingChallengeCredits, freeDaysForTenant, recomputeReferrerMilestones,
  };
}
