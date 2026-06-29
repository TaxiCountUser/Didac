// ============================================================================
// gamification.js — Loop #4: recompensas TRIMESTRALES por % de flota activa.
//
// Sustituye el modelo insostenible "1 mes gratis al JEFE por cada conductor que
// completa un ciclo" por uno trimestral: se mide qué % de la flota ACTIVA logró
// al menos un reto épico en el trimestre y se premia al tenant según una tabla.
//
// Reglas de negocio (RN):
//   RN-05  Cada conductor cuenta 1 sola vez en el numerador (DISTINCT).
//   RN-06  Conductores inactivos (>30 días sin km) no entran en el denominador.
//   RN-13  Recompensa máxima 30 días/trimestre (=> 4 meses/año como tope natural).
//   RN-21  Los retos no se reinician: el numerador filtra por created_at del claim
//          dentro del trimestre (no se borra ni resetea challenge_claims).
//
// Nota de reconciliación con el spec genérico:
//   - El esquema real usa users.active (no is_active) y odometer_readings.taken_at
//     (no reading_date). challenge_claims no tiene completed_at -> usamos created_at.
//   - "drivers_with_achievement" cuenta conductores con >=1 claim (no rechazado)
//     creado dentro del trimestre. En este código cada claim YA representa un logro
//     épico real (100k km / 100k € / 300 días), así que no se restringe por nivel.
// ============================================================================

const DAY_MS = 86400000;

// Trimestre (1..4) al que pertenece una fecha.
export function quarterOf(date = new Date()) {
  const d = date instanceof Date ? date : new Date(date);
  const year = d.getUTCFullYear();
  const quarter = Math.floor(d.getUTCMonth() / 3) + 1; // 0-2->1, 3-5->2, ...
  return { year, quarter };
}

// Inicio (inclusive) y fin (exclusivo) de un trimestre, en ISO UTC.
export function quarterRange(year, quarter) {
  const startMonth = (quarter - 1) * 3; // 0,3,6,9
  const start = new Date(Date.UTC(year, startMonth, 1, 0, 0, 0));
  const next = new Date(Date.UTC(year, startMonth + 3, 1, 0, 0, 0));
  return { startISO: start.toISOString(), nextISO: next.toISOString() };
}

export function quarterLabel(year, quarter) {
  return `${year}-Q${quarter}`;
}

// ¿Hoy es el último día de un trimestre? (para el scheduler diario).
export function isLastDayOfQuarter(date = new Date()) {
  const d = date instanceof Date ? date : new Date(date);
  const tomorrow = new Date(d.getTime() + DAY_MS);
  // Cambia de trimestre entre hoy y mañana.
  const a = quarterOf(d);
  const b = quarterOf(tomorrow);
  return a.year !== b.year || a.quarter !== b.quarter;
}

// Tabla de recompensa según la tasa de completitud (0..100).
export function rewardDaysForRate(rate) {
  if (rate >= 90) return 30;
  if (rate >= 75) return 15;
  if (rate >= 50) return 7;
  return 0;
}

// Mensaje motivador para el JEFE según la tasa lograda.
export function rewardMessage(rate, days) {
  const pct = Math.round(rate);
  if (days === 0) {
    return `Tu flota completó retos al ${pct}% este trimestre. ¡Anima a tus conductores para llegar al 50% y ganar días gratis!`;
  }
  if (days === 7) return `¡Bien! Tu flota llegó al ${pct}%. Has ganado 7 días gratis de suscripción.`;
  if (days === 15) return `¡Excelente! Tu flota llegó al ${pct}%. Has ganado 15 días gratis de suscripción.`;
  return `¡Increíble! Tu flota llegó al ${pct}%. Has ganado 1 mes gratis (30 días) de suscripción.`;
}

// Extiende la suscripción del tenant N días (sobre el final actual o desde hoy si
// ya venció). Es la "extend_tenant_subscription" que pedía el spec; aquí el premio
// se materializa empujando tenants.trial_ends_at, igual que el resto del sistema.
export async function extendTenantSubscription(supabase, tenantId, days) {
  if (!days || days <= 0) return null;
  const { data: t } = await supabase
    .from('tenants').select('trial_ends_at').eq('id', tenantId).maybeSingle();
  const now = Date.now();
  const cur = t?.trial_ends_at ? new Date(t.trial_ends_at).getTime() : now;
  const base = cur > now ? cur : now;
  const next = new Date(base + days * DAY_MS).toISOString();
  await supabase.from('tenants').update({ trial_ends_at: next }).eq('id', tenantId);
  return next;
}

// Calcula las métricas de un tenant para un trimestre dado.
// Devuelve { active_drivers, drivers_with_achievement, completion_rate }.
export async function computeTenantQuarterMetrics(supabase, tenantId, range, since30ISO) {
  // 1) Conductores activos del tenant (rol driver + activo).
  const { data: drivers } = await supabase
    .from('users')
    .select('id')
    .eq('tenant_id', tenantId)
    .eq('role', 'driver')
    .eq('active', true);
  const driverIds = new Set((drivers ?? []).map((d) => d.id));
  if (driverIds.size === 0) {
    return { active_drivers: 0, drivers_with_achievement: 0, completion_rate: 0 };
  }

  // 2) RN-06: de esos, los que tienen ALGUNA lectura de km en los últimos 30 días.
  const { data: recentReads } = await supabase
    .from('odometer_readings')
    .select('user_id')
    .eq('tenant_id', tenantId)
    .gte('taken_at', since30ISO);
  const activeSet = new Set();
  for (const r of recentReads ?? []) {
    if (driverIds.has(r.user_id)) activeSet.add(r.user_id);
  }
  const activeDrivers = activeSet.size;
  if (activeDrivers === 0) {
    return { active_drivers: 0, drivers_with_achievement: 0, completion_rate: 0 };
  }

  // 3) RN-05/RN-21: conductores ACTIVOS con >=1 claim (no rechazado) creado DENTRO
  //    del trimestre. DISTINCT por user_id -> cada conductor cuenta una vez.
  const { data: claims } = await supabase
    .from('challenge_claims')
    .select('user_id, status, created_at')
    .eq('tenant_id', tenantId)
    .gte('created_at', range.startISO)
    .lt('created_at', range.nextISO)
    .neq('status', 'rejected');
  const achieved = new Set();
  for (const c of claims ?? []) {
    if (activeSet.has(c.user_id)) achieved.add(c.user_id);
  }
  const driversWithAchievement = achieved.size;

  const rate = activeDrivers > 0
    ? Math.round((driversWithAchievement / activeDrivers) * 10000) / 100 // 2 decimales
    : 0;

  return {
    active_drivers: activeDrivers,
    drivers_with_achievement: driversWithAchievement,
    completion_rate: rate,
  };
}

// Ejecuta el cálculo trimestral para TODOS los tenants y aplica recompensas.
// opts: { year, quarter, dryRun, notifyOwner, log }
//   - notifyOwner(tenantId, title, body, data): callback para push al JEFE.
//   - dryRun: si true, calcula y persiste métricas pero NO extiende suscripción
//             ni notifica (útil para validar).
// Devuelve un resumen { period, tenants_processed, rewards_granted, results }.
export async function runQuarterlyFleetRewards(supabase, opts = {}) {
  const log = opts.log ?? console;
  const startedAt = new Date();
  const { year, quarter } = (opts.year && opts.quarter)
    ? { year: opts.year, quarter: opts.quarter }
    : quarterOf();
  const range = quarterRange(year, quarter);
  const period = quarterLabel(year, quarter);
  const since30ISO = new Date(Date.now() - 30 * DAY_MS).toISOString();
  const dryRun = !!opts.dryRun;

  // Log de auditoría en estado "running".
  let logId = null;
  try {
    const { data: logRow } = await supabase
      .from('cron_execution_logs')
      .insert({ job_name: 'fleet_quarterly_rewards', period_label: period, status: 'running' })
      .select('id').maybeSingle();
    logId = logRow?.id ?? null;
  } catch (e) { log.warn?.(`[cron] no se pudo crear log: ${e.message}`); }

  const results = [];
  let rewardsGranted = 0;

  try {
    const { data: tenants, error } = await supabase.from('tenants').select('id, name');
    if (error) throw new Error(error.message);

    for (const t of tenants ?? []) {
      const m = await computeTenantQuarterMetrics(supabase, t.id, range, since30ISO);
      const rewardDays = rewardDaysForRate(m.completion_rate);

      // Upsert idempotente en fleet_quarterly_metrics (unique tenant+year+quarter).
      const row = {
        tenant_id: t.id, year, quarter,
        active_drivers: m.active_drivers,
        drivers_with_achievement: m.drivers_with_achievement,
        completion_rate: m.completion_rate,
        reward_days_awarded: dryRun ? 0 : rewardDays,
        processed_at: new Date().toISOString(),
      };
      await supabase.from('fleet_quarterly_metrics')
        .upsert(row, { onConflict: 'tenant_id,year,quarter' });

      let extendedTo = null;
      if (!dryRun && rewardDays > 0) {
        extendedTo = await extendTenantSubscription(supabase, t.id, rewardDays);
        rewardsGranted += 1;
        // Push al JEFE (owner) del tenant.
        if (opts.notifyOwner) {
          const { data: owners } = await supabase
            .from('users').select('id').eq('tenant_id', t.id).eq('role', 'owner');
          for (const o of owners ?? []) {
            await opts.notifyOwner(o.id,
              'Recompensa de flota 🏆',
              rewardMessage(m.completion_rate, rewardDays),
              { type: 'fleet_reward', year: String(year), quarter: String(quarter), days: String(rewardDays) });
          }
        }
      }

      results.push({
        tenant_id: t.id, name: t.name,
        ...m, reward_days_awarded: dryRun ? 0 : rewardDays,
        extended_to: extendedTo,
      });
    }

    const finishedAt = new Date();
    if (logId) {
      await supabase.from('cron_execution_logs').update({
        finished_at: finishedAt.toISOString(),
        status: 'success',
        tenants_processed: results.length,
        rewards_granted: rewardsGranted,
        details: { period, dryRun, results: results.slice(0, 500) },
      }).eq('id', logId);
    }

    return {
      period, year, quarter, dryRun,
      tenants_processed: results.length,
      rewards_granted: rewardsGranted,
      duration_ms: finishedAt.getTime() - startedAt.getTime(),
      results,
    };
  } catch (e) {
    log.error?.(`[cron] fleet_quarterly_rewards falló: ${e.message}`);
    if (logId) {
      await supabase.from('cron_execution_logs').update({
        finished_at: new Date().toISOString(),
        status: 'error', error: e.message,
        tenants_processed: results.length, rewards_granted: rewardsGranted,
      }).eq('id', logId);
    }
    throw e;
  }
}

// Scheduler ligero SIN dependencias: comprueba 1 vez/día si hoy es el último día
// de un trimestre y, en tal caso, ejecuta el reparto (idempotente por el unique
// de fleet_quarterly_metrics). Devuelve un handle con stop().
//
// Se usa setInterval horario en vez de node-cron para no añadir dependencias y
// porque "último día de trimestre" no es expresable directamente en cron. La
// idempotencia (upsert + unique) hace inocuo que se dispare más de una vez.
export function scheduleQuarterly(supabase, opts = {}) {
  const log = opts.log ?? console;
  const HOUR_MS = 3600000;
  let lastRunPeriod = null;

  async function tick() {
    try {
      const now = new Date();
      if (!isLastDayOfQuarter(now)) return;
      // Disparar a partir de las 23:00 UTC del último día.
      if (now.getUTCHours() < 23) return;
      const { year, quarter } = quarterOf(now);
      const period = quarterLabel(year, quarter);
      if (lastRunPeriod === period) return; // ya lo corrimos en este proceso
      lastRunPeriod = period;
      log.info?.(`[cron] Ejecutando reparto trimestral ${period}…`);
      const summary = await runQuarterlyFleetRewards(supabase, { ...opts, year, quarter });
      log.info?.(`[cron] ${period} ok: ${summary.tenants_processed} tenants, ${summary.rewards_granted} premios.`);
    } catch (e) {
      log.error?.(`[cron] tick trimestral falló: ${e.message}`);
    }
  }

  // Primer chequeo al arrancar (por si el proceso revive justo en quarter-end) y
  // luego cada hora.
  tick();
  const handle = setInterval(tick, HOUR_MS);
  if (handle.unref) handle.unref();
  return { stop: () => clearInterval(handle) };
}
