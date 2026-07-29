// ============================================================
// TaxiCount - Retos / metas por conductor (challenges). Fase B del troceig.
// Plugin de rutas: registra los 7 endpoints de retos (progreso de conductor y
// de flota, panel admin, aprobar/rechazar con clawback de crédito Stripe) + sus
// 4 helpers exclusivos (challengeConfig, incrementFor, levelState,
// challengeStatusLabel). Sin cambio de comportamiento: las deps del closure
// buildApp() se inyectan por parámetro. NOTA: el cron apply-challenge-credits y
// el endpoint mixto /tenant/free-days se quedan en server.js a propósito.
// ============================================================

export function registerRetosRoutes(app, {
  supabase, adminGuard, getCaller, logAdminAction, reverseRewardCredit, log,
  readGlobalRevenue,
}) {
  // ============================================================
  // Retos / metas por conductor (km_100k, money_100k, days_300), ESCALONADOS.
  // Solo los empresarios (owner) ven el progreso de SUS conductores. Cada reto
  // tiene niveles: el nivel 1 pide la base (100.000 km / 100.000 € / 300 días);
  // a partir del nivel 2, el DOBLE (200.000 / 200.000 / 600), y se repite. Es
  // INCREMENTAL: el progreso se mide desde el valor que tenía la métrica al
  // empezar el tramo (baseline). El siguiente nivel NO se ve hasta que la
  // administración aprueba el actual. Premio NO automático (lo aprueba el admin).
  // Anti-fraude: días activos < 300 -> sospechoso; max_jump grande -> km inflado.
  // ============================================================
  // Loop #6: TODOS los parámetros de retos se leen de system_config (editables
  // desde el panel de admin sin desplegar). Valores por defecto entre paréntesis:
  //   challenge_100k_euros_enabled (false) - money_100k solo si 'true'
  //   challenge_days_required      (365)   - objetivo del reto de días
  //   challenge_km_target          (100000)- objetivo de km del nivel 1
  //   challenge_max_jump           (2000)  - salto de km sospechoso (anti-fraude)
  //   challenge_max_income         (1500)  - carrera € sospechosa (anti-fraude)
  // La clave interna 'days_300' se mantiene por compatibilidad de datos/UI.
  // Loop #8: la recompensa ya NO se configura (challenge_seat_credit_cents
  // obsoleta) — es annual_price_paid/12 del conductor, ver applyPendingChallengeCredits.
  async function challengeConfig() {
    let euros = false;
    let days = 365;
    let kmTarget = 100000;
    let moneyTarget = 100000;
    let maxJump = 2000;
    let maxIncome = 1500;
    let kmEnabled = true;
    let daysEnabled = true;
    let levelMultiplier = 2;
    let levelCycle = 4;
    try {
      const { data } = await supabase.from('system_config')
        .select('key, value')
        .in('key', ['challenge_100k_euros_enabled', 'challenge_days_required',
          'challenge_km_target', 'challenge_money_target', 'challenge_max_jump',
          'challenge_max_income', 'challenge_km_enabled', 'challenge_days_enabled',
          'challenge_level_multiplier', 'challenge_level_cycle']);
      for (const r of data ?? []) {
        switch (r.key) {
          case 'challenge_100k_euros_enabled': euros = r.value === 'true'; break;
          case 'challenge_days_required': days = parseInt(r.value, 10) || days; break;
          case 'challenge_km_target': kmTarget = parseInt(r.value, 10) || kmTarget; break;
          case 'challenge_money_target': moneyTarget = parseInt(r.value, 10) || moneyTarget; break;
          case 'challenge_max_jump': maxJump = parseInt(r.value, 10) || maxJump; break;
          case 'challenge_max_income': maxIncome = parseInt(r.value, 10) || maxIncome; break;
          case 'challenge_km_enabled': kmEnabled = r.value !== 'false'; break;
          case 'challenge_days_enabled': daysEnabled = r.value !== 'false'; break;
          case 'challenge_level_multiplier': levelMultiplier = parseInt(r.value, 10) || levelMultiplier; break;
          case 'challenge_level_cycle': levelCycle = parseInt(r.value, 10) || levelCycle; break;
          default: break;
        }
      }
    } catch { /* sin config -> valores por defecto */ }
    const base = {};
    if (kmEnabled) base.km_100k = kmTarget;
    if (euros) base.money_100k = moneyTarget;
    if (daysEnabled) base.days_300 = days;
    return {
      base, eurosEnabled: euros, daysRequired: days, maxJump, maxIncome,
      levelMultiplier, levelCycle,
    };
  }

  // Objetivo (incremento) de un reto en un nivel dado. Ciclo configurable: el
  // 1º de cada ciclo (niveles 1, cycle+1, 2·cycle+1...) vuelve a la base; los
  // demás, la base × multiplicador. Así de vez en cuando "baja" como sorpresa.
  const incrementFor = (base, challenge, level, mult = 2, cycle = 4) =>
    (base[challenge] ?? 0) * (((level - 1) % Math.max(1, cycle)) === 0 ? 1 : mult);

  // A partir de los claims de un conductor+reto, calcula el nivel actual, el
  // baseline (métrica al empezar el tramo) y si hay un claim pendiente/rechazado.
  function levelState(claims) {
    let maxRewarded = 0;
    let baselineForNext = 0;
    for (const c of claims) {
      if (c.status === 'rewarded' && c.level > maxRewarded) {
        maxRewarded = c.level;
        baselineForNext = Number(c.metric_value ?? 0);
      }
    }
    const level = maxRewarded + 1;
    const baseline = maxRewarded > 0 ? baselineForNext : 0;
    const atCurrent = claims.find((c) => c.level === level);
    return { level, baseline, pending: atCurrent?.status === 'pending', rejected: atCurrent?.status === 'rejected' };
  }

  // Progreso de los retos de TODOS los conductores de la empresa (solo owner).
  app.get('/api/v1/challenges/company', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (caller.role !== 'owner') {
      return reply.code(403).send({ error: 'Solo el propietario ve los retos' });
    }
    try {
      const { base, maxJump: maxJumpCfg, maxIncome: maxIncomeCfg, levelMultiplier, levelCycle } = await challengeConfig();
      const { data: stats, error } = await supabase.rpc('challenge_stats_tenant', { p_tenant: caller.tenant_id });
      if (error) throw new Error(error.message);

      // Todos los claims de la empresa, agrupados por conductor+reto.
      const { data: allClaims } = await supabase
        .from('challenge_claims')
        .select('user_id, challenge, level, metric_value, status')
        .eq('tenant_id', caller.tenant_id);
      const byUserChal = {};
      for (const c of allClaims ?? []) {
        ((byUserChal[c.user_id] ??= {})[c.challenge] ??= []).push(c);
      }

      const drivers = [];
      for (const r of stats ?? []) {
        const metrics = {
          km_100k: Number(r.km ?? 0),
          money_100k: Number(r.money ?? 0),
          days_300: Number(r.active_days ?? 0),
        };
        const activeDays = Number(r.active_days ?? 0);
        const maxJump = Number(r.max_jump ?? 0);
        const maxIncome = Number(r.max_income ?? 0);
        const challenges = [];
        for (const type of Object.keys(base)) {
          const claims = (byUserChal[r.user_id]?.[type]) ?? [];
          const st = levelState(claims);
          const target = incrementFor(base, type, st.level, levelMultiplier, levelCycle);
          const metric = metrics[type];
          const progress = Math.max(0, metric - st.baseline);
          const reached = progress >= target;
          // Loop #6: al alcanzar el tramo se registra el logro como 'rewarded'
          // (auto-avance de nivel). La recompensa es 1 mes-asiento gratis al jefe
          // por conductor, que se aplica como crédito en Stripe (cron). Si hay
          // señales de fraude se marca `suspicious` para que lo revise el ADMIN
          // (ya no se avisa al jefe); el admin puede rechazarlo.
          if (reached && !st.pending && !st.rejected) {
            const suspicious = (type === 'km_100k' && maxJump > maxJumpCfg)
              || (type === 'money_100k' && maxIncome > maxIncomeCfg);
            // Un logro SOSPECHOSO entra como 'pending' (lo revisa el admin): así
            // NO cuenta como completado ni cobra recompensa hasta que se acepta.
            // Los logros limpios siguen auto-aprobados ('rewarded'), sin fricción.
            const { error: insErr } = await supabase.from('challenge_claims').insert({
              tenant_id: caller.tenant_id, user_id: r.user_id, challenge: type,
              level: st.level, baseline: st.baseline, target,
              metric_value: metric, active_days: activeDays, suspicious,
              status: suspicious ? 'pending' : 'rewarded',
              reviewed_at: suspicious ? null : new Date().toISOString(),
            });
            if (insErr && !/duplicate|unique|23505/i.test(insErr.message || '')) {
              log.warn(`[challenge] no se pudo crear claim: ${insErr.message}`);
            }
          }
          challenges.push({
            type, level: st.level, target, progress,
            remaining: Math.max(0, target - progress),
            pct: target > 0 ? Math.min(1, progress / target) : 0,
            reached, pending: st.pending, rejected: st.rejected,
          });
        }
        // NOTA: el aviso anti-fraude (salto de km / carrera enorme) ya NO se
        // envía al jefe; se marca en el claim y lo revisa el admin.
        drivers.push({
          user_id: r.user_id, name: r.name, email: r.email,
          challenges,
        });
      }
      return reply.send({ drivers });
    } catch (e) {
      request.log.error(e);
      return reply.code(500).send({ error: 'No se pudieron calcular los retos' });
    }
  });

  // Loop #6: retos del PROPIO conductor (para que los vea en su app). Devuelve su
  // progreso por reto (km / días), con nivel y objetivo actuales.
  app.get('/api/v1/challenges/mine', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    try {
      const { base, levelMultiplier, levelCycle } = await challengeConfig();
      const { data: stats } = await supabase.rpc('challenge_stats', { p_user: caller.id });
      const row = Array.isArray(stats) ? (stats[0] ?? {}) : (stats ?? {});
      const metrics = {
        km_100k: Number(row.km ?? 0),
        money_100k: Number(row.money ?? 0),
        days_300: Number(row.active_days ?? 0),
      };
      const { data: claims } = await supabase.from('challenge_claims')
        .select('challenge, level, metric_value, status').eq('user_id', caller.id);
      const byChal = {};
      for (const c of claims ?? []) (byChal[c.challenge] ??= []).push(c);
      const challenges = [];
      for (const type of Object.keys(base)) {
        const st = levelState(byChal[type] ?? []);
        const target = incrementFor(base, type, st.level, levelMultiplier, levelCycle);
        const metric = metrics[type];
        const progress = Math.max(0, metric - st.baseline);
        challenges.push({
          type, level: st.level, target, progress,
          remaining: Math.max(0, target - progress),
          pct: target > 0 ? Math.min(1, progress / target) : 0,
          reached: progress >= target,
        });
      }
      return reply.send({ challenges });
    } catch (e) {
      request.log.error(e);
      return reply.code(500).send({ error: 'No se pudieron calcular tus retos' });
    }
  });

  // Estado del claim normalizado a la nomenclatura del dashboard. Loop #4 hace
  // que los logros se auto-registren como 'rewarded' (=approved); 'pending' es
  // legado (ya no se genera). 'rejected' = rechazado por fraude.
  const challengeStatusLabel = (s) =>
    s === 'rewarded' ? 'approved' : (s === 'rejected' ? 'rejected' : 'pending');

  // Admin: lista de retos (de todas las empresas) con nivel, último reto
  // completado y estado normalizado. Filtros: ?level= y ?status=.
  app.get('/api/v1/admin/challenges', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { data, error } = await supabase
      .from('challenge_claims')
      .select('id, user_id, tenant_id, challenge, level, target, baseline, metric_value, active_days, '
        + 'suspicious, status, created_at, reviewed_at, users:user_id(email, name), tenants:tenant_id(name)')
      .order('created_at', { ascending: false });
    if (error) return reply.code(500).send({ error: error.message });

    // Último reto completado (rewarded) por conductor, para mostrarlo en cada fila.
    const lastCompletedByUser = {};
    for (const r of data ?? []) {
      if (r.status === 'rewarded' && r.reviewed_at) {
        const cur = lastCompletedByUser[r.user_id];
        if (!cur || new Date(r.reviewed_at) > new Date(cur)) lastCompletedByUser[r.user_id] = r.reviewed_at;
      }
    }

    let rows = (data ?? []).map((r) => ({
      ...r,
      status_label: challengeStatusLabel(r.status),
      last_completed: lastCompletedByUser[r.user_id] ?? null,
      // Loop #6: el anti-fraude lo revisa el admin. `suspicious` viene marcado en
      // el claim cuando el logro tuvo un salto de km / carrera enorme.
      suspicious: r.suspicious === true,
    }));

    const fLevel = request.query?.level;
    if (fLevel != null && fLevel !== '') {
      const lvl = parseInt(fLevel, 10);
      rows = rows.filter((r) => (r.level ?? 0) === lvl);
    }
    const fStatus = request.query?.status;
    if (fStatus) rows = rows.filter((r) => r.status_label === fStatus);

    return reply.send({ claims: rows });
  });

  // Admin: KPIs de super retos (resumen global).
  app.get('/api/v1/admin/challenges/summary', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { data: claims } = await supabase.from('challenge_claims')
      .select('user_id, level, status, created_at, reviewed_at').limit(20000);
    const { count: totalDrivers } = await supabase.from('users')
      .select('id', { count: 'exact', head: true }).eq('role', 'driver');

    const now = new Date();
    const dayMs = 86400000;
    const monthStart = new Date(now.getUTCFullYear(), now.getUTCMonth(), 1).getTime();
    // Serie diaria de retos completados (últimos 30 días), por fecha ISO.
    const daily = {};
    for (let i = 29; i >= 0; i--) {
      const d = new Date(now.getTime() - i * dayMs).toISOString().slice(0, 10);
      daily[d] = 0;
    }

    let totalCompleted = 0;
    let pendingApprovals = 0;
    let rejected = 0;
    let completedThisMonth = 0;
    const driversWithClaim = new Set();
    for (const c of claims ?? []) {
      if (c.status === 'rewarded') {
        // Solo cuenta como "conductor con reto" quien tiene un logro COMPLETADO
        // (rewarded); los pendientes/rechazados no cuentan (si no, un fraude
        // rechazado seguiría inflando el %).
        driversWithClaim.add(c.user_id);
        totalCompleted += 1;
        const when = c.reviewed_at || c.created_at;
        if (when) {
          const t = new Date(when).getTime();
          if (t >= monthStart) completedThisMonth += 1;
          const key = new Date(when).toISOString().slice(0, 10);
          if (key in daily) daily[key] += 1;
        }
      } else if (c.status === 'pending') {
        pendingApprovals += 1;
      } else if (c.status === 'rejected') {
        rejected += 1;
      }
    }
    const driversWithChallenge = totalDrivers
      ? +((driversWithClaim.size / totalDrivers) * 100).toFixed(1) : 0;
    // Tasa de compleción = completados / intentos decididos (completados + pendientes
    // + rechazados). Ratio, no volumen (estándar de analítica de engagement).
    const attempts = totalCompleted + pendingApprovals + rejected;
    const completionRate = attempts > 0
      ? +((totalCompleted / attempts) * 100).toFixed(1) : 0;
    // Tasa de fraude = rechazados / (completados + rechazados).
    const fraudRate = (totalCompleted + rejected) > 0
      ? +((rejected / (totalCompleted + rejected)) * 100).toFixed(1) : 0;

    // COSTE real del programa de retos = suma de los CRÉDITOS Stripe concedidos
    // (cada reto completado = 1 asiento·mes a la tarifa efectiva del cliente). Y
    // qué % del valor bruto (cobrado + regalado) supone. Conecta con Facturación.
    const { data: extRows } = await supabase.from('subscription_extensions')
      .select('credit_cents').eq('extension_type', 'challenge').limit(20000);
    const rewardCount = (extRows ?? []).length;
    const rewardCostEur = +((extRows ?? [])
      .reduce((s, r) => s + (r.credit_cents ?? 0), 0) / 100).toFixed(2);
    const rev = await readGlobalRevenue();
    const cashTotal = ((rev?.paid ?? 0) - (rev?.refunded ?? 0)) / 100;
    const rewardPct = (cashTotal + rewardCostEur) > 0
      ? +((rewardCostEur / (cashTotal + rewardCostEur)) * 100).toFixed(1) : 0;

    // Evolución de km RECORRIDOS por día (global, últimos 30 días): muestra cómo
    // AVANZAN los conductores hacia los retos, no solo cuándo los completan.
    // Best-effort: si la RPC no está (migración 067 sin aplicar) devuelve [].
    let kmDaily = [];
    try {
      const { data: km } = await supabase.rpc('challenge_km_daily', { p_days: 30 });
      kmDaily = (km ?? []).map((r) => ({ date: r.day, km: Math.round(Number(r.km) || 0) }));
    } catch { /* RPC ausente: sin serie de km */ }

    return reply.send({
      total_completed: totalCompleted,
      drivers_with_challenge: driversWithChallenge, // %
      completion_rate: completionRate, // % completados / intentos
      reward_count: rewardCount, // nº de recompensas concedidas
      reward_cost_eur: rewardCostEur, // € regalados en recompensas
      reward_pct: rewardPct, // % del valor bruto que regalamos
      pending_approvals: pendingApprovals,
      rejected,
      fraud_rate: fraudRate, // %
      completed_this_month: completedThisMonth,
      daily: Object.entries(daily).map(([date, count]) => ({ date, count })),
      km_daily: kmDaily,
    });
  });

  // Admin: detalle ampliado de un reto -> historial completo del conductor,
  // niveles actuales por reto y comparativa con la media de su flota.
  app.get('/api/v1/admin/challenges/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { data: claim } = await supabase.from('challenge_claims')
      .select('id, user_id, tenant_id, challenge, level, status, created_at, reviewed_at, '
        + 'users:user_id(email, name), tenants:tenant_id(name)')
      .eq('id', request.params.id).maybeSingle();
    if (!claim) return reply.code(404).send({ error: 'Reto no encontrado' });

    // Historial completo del conductor (todos sus claims, ordenados).
    const { data: history } = await supabase.from('challenge_claims')
      .select('id, challenge, level, target, baseline, metric_value, status, created_at, reviewed_at')
      .eq('user_id', claim.user_id)
      .order('created_at', { ascending: true });

    // Niveles actuales por reto (derivados de los claims rewarded).
    const byChal = {};
    for (const c of history ?? []) ((byChal[c.challenge] ??= []).push(c));
    const currentLevels = {};
    const { base } = await challengeConfig();
    for (const type of Object.keys(base)) {
      currentLevels[type] = levelState(byChal[type] ?? []).level;
    }

    // Comparativa con la flota: nivel máximo aprobado medio en el mismo tenant.
    const { data: tenantClaims } = await supabase.from('challenge_claims')
      .select('user_id, level, status').eq('tenant_id', claim.tenant_id).eq('status', 'rewarded').limit(20000);
    const maxByUser = {};
    for (const c of tenantClaims ?? []) {
      if (!maxByUser[c.user_id] || (c.level ?? 1) > maxByUser[c.user_id]) maxByUser[c.user_id] = c.level ?? 1;
    }
    const vals = Object.values(maxByUser);
    const fleetAvgLevel = vals.length ? +(vals.reduce((s, n) => s + n, 0) / vals.length).toFixed(1) : 0;

    // PROTECCIÓN DE DATOS: en el reto de dinero (money_100k) las métricas son
    // euros de la empresa -> se enmascaran para el admin (no ve importes).
    const maskMoney = (h) => (h.challenge === 'money_100k'
      ? { ...h, metric_value: null, target: null, baseline: null, money_masked: true }
      : h);
    return reply.send({
      claim,
      driver_history: (history ?? []).map((h) =>
        ({ ...maskMoney(h), status_label: challengeStatusLabel(h.status) })),
      current_levels: currentLevels,
      fleet_avg_level: fleetAvgLevel,
    });
  });

  // Admin: forzar la finalización (aprobación) de un reto. Requiere justificación
  // (reason) y queda registrado en auditoría. No extiende suscripción (Loop #4).
  app.post('/api/v1/admin/challenges/:id/force-complete', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const reason = (request.body ?? {}).reason;
    if (!reason || !String(reason).trim()) {
      return reply.code(400).send({ error: 'Se requiere una justificación (reason)' });
    }
    const { data: claim } = await supabase.from('challenge_claims')
      .select('id, user_id, status').eq('id', request.params.id).maybeSingle();
    if (!claim) return reply.code(404).send({ error: 'Reto no encontrado' });
    await supabase.from('challenge_claims')
      .update({ status: 'rewarded', reviewed_at: new Date().toISOString() }).eq('id', claim.id);
    await logAdminAction(request, g.caller.id, 'challenge_force_complete', 'challenge', claim.id,
      { reason: String(reason), previous_status: claim.status });
    return reply.send({ ok: true });
  });

  // Admin: revisar un reto. Loop #4: la recompensa individual (mes gratis por
  // claim) está DESACTIVADA — los días gratis se reparten trimestralmente por %
  // de flota (cron). 'reject' sigue activo como control de FRAUDE: un claim
  // rechazado no cuenta en la métrica trimestral (drivers_with_achievement). La
  // acción 'reward' se conserva por compatibilidad pero ya NO extiende ninguna
  // suscripción (los retos se auto-registran como 'rewarded' al alcanzarse).
  app.post('/api/v1/admin/challenges/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const action = (request.body ?? {}).action;
    const reason = String((request.body ?? {}).reason ?? '').trim().slice(0, 300);
    if (action !== 'reward' && action !== 'reject') {
      return reply.code(400).send({ error: 'Acción no válida' });
    }
    const { data: claim, error: cErr } = await supabase
      .from('challenge_claims').select('id, tenant_id, status, reward_redeemed_at')
      .eq('id', request.params.id).maybeSingle();
    if (cErr || !claim) return reply.code(404).send({ error: 'Reto no encontrado' });

    if (action === 'reject') {
      // Si el logro YA se había premiado (crédito Stripe aplicado por el cron), se
      // revierte con clawback (b): se retira el crédito NO consumido y se borra la
      // recompensa, para que el logro rechazado DESAPAREZCA de "completados" y del
      // crédito acumulado. Si el crédito ya se gastó, se asume (no se cobra de más).
      let clawedCents = 0;
      if (claim.reward_redeemed_at) {
        const { data: exts } = await supabase.from('subscription_extensions')
          .select('id, credit_cents')
          .eq('source_id', claim.id).eq('extension_type', 'challenge');
        clawedCents = (exts ?? []).reduce((s, e) => s + (e.credit_cents ?? 0), 0);
        if (clawedCents > 0) {
          const { data: tRow } = await supabase.from('tenants')
            .select('stripe_customer_id').eq('id', claim.tenant_id).maybeSingle();
          await reverseRewardCredit(tRow?.stripe_customer_id, clawedCents);
        }
        if ((exts ?? []).length) {
          await supabase.from('subscription_extensions')
            .delete().eq('source_id', claim.id).eq('extension_type', 'challenge');
        }
      }
      await supabase.from('challenge_claims')
        .update({ status: 'rejected', reviewed_at: new Date().toISOString(), reward_redeemed_at: null })
        .eq('id', claim.id);
      await logAdminAction(request, g.caller?.id ?? null, 'challenge_reject',
        'challenge_claims', claim.id, { clawed_back_cents: clawedCents, reason: reason || null });
      return reply.send({ ok: true, rejected: true, clawed_back_cents: clawedCents });
    }

    // action === 'reward': aprueba un logro pendiente (sospechoso) -> pasa a
    // contar como completado y el cron aplicará la recompensa (si es de pago).
    await supabase.from('challenge_claims')
      .update({ status: 'rewarded', reviewed_at: new Date().toISOString() })
      .eq('id', claim.id);
    await logAdminAction(request, g.caller?.id ?? null, 'challenge_reward',
      'challenge_claims', claim.id, null);
    return reply.send({ ok: true, rewarded: true });
  });
}
