// ============================================================
// TaxiCount - Referidos ("Invita y Gana"). Fase B del troceig.
// Plugin de rutas: 15 endpoints (código/compartir/validar/historial/progreso del
// conductor-owner + panel admin: lista, KPIs, resolver, config, escaneo, bloquear/
// desbloquear) y sus 4 helpers exclusivos, INCLUIDO el anti-fraude de referidos
// (createFraudAlert, runFraudChecks — el escaneo que se dejó fuera de fraud.js).
//
// Sin cambio de comportamiento. Se inyectan: refConfig y milestonesFrom (viven en
// server.js porque los comparte rewards.js — evita dependencia circular) y
// recomputeReferrerMilestones (de rewards.js, para el clawback al validar/bloquear).
// NOTA: quedan en server.js el cron process-referral-validations y los helpers de
// cola/reversión (revertReferralForTenant, enqueue/reject, processReferralValidationQueue)
// porque los comparte el webhook de billing.js.
// ============================================================

export function registerReferralsRoutes(app, {
  supabase, adminGuard, getCaller, logAdminAction,
  refConfig, milestonesFrom, recomputeReferrerMilestones,
}) {
  // ¿Puede invitar? Owner/autónomo con suscripción activa de pago
  // o en periodo de prueba todavía vigente.
  async function isReferralEligible(caller) {
    if (!caller || caller.role !== 'owner' || !caller.tenant_id) return false;
    const { data: t } = await supabase
      .from('tenants').select('subscription_status, trial_ends_at')
      .eq('id', caller.tenant_id).maybeSingle();
    if (!t) return false;
    if (t.subscription_status === 'active' || t.subscription_status === 'past_due') return true;
    const trialVigente = t.trial_ends_at && new Date() < new Date(t.trial_ends_at);
    return trialVigente === true;
  }

  // Devuelve el código del usuario; si no tiene, genera uno único "TX"+6.
  async function ensureReferralCode(userId) {
    const { data: existing } = await supabase
      .from('referral_codes').select('code').eq('user_id', userId).maybeSingle();
    if (existing) return existing.code;
    const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    // Aleatoriedad criptográfica (evita predicción/colisión de Math.random).
    // Rechazo de bytes >= 256 - (256 % len) para no introducir sesgo de módulo.
    const pickChar = () => {
      const max = 256 - (256 % ALPHABET.length);
      let b;
      do { b = randomBytes(1)[0]; } while (b >= max);
      return ALPHABET[b % ALPHABET.length];
    };
    for (let i = 0; i < 6; i++) {
      const code = 'TX' + Array.from({ length: 6 }, pickChar).join('');
      const { error } = await supabase.from('referral_codes').insert({ user_id: userId, code });
      if (!error) return code;
      if (!/duplicate|unique|23505/i.test(error.message || '')) throw new Error(error.message);
      // 23505 en (user_id) = otro proceso lo creó: devuélvelo
      const { data: again } = await supabase
        .from('referral_codes').select('code').eq('user_id', userId).maybeSingle();
      if (again) return again.code;
    }
    throw new Error('No se pudo generar el código de referido');
  }

  // --- Anti-fraude de referidos (Iteración 4) -----------------------------
  // Dominios de email desechables más habituales (ampliable por config).
  const DISPOSABLE_EMAIL_DOMAINS = [
    'mailinator.com', 'tempmail.com', '10minutemail.com', 'guerrillamail.com',
    'yopmail.com', 'trashmail.com', 'sharklasers.com', 'getnada.com',
    'temp-mail.org', 'dispostable.com', 'maildrop.cc', 'fakeinbox.com',
  ];

  // Crea una alerta, evitando duplicar una abierta del mismo tipo/referral.
  async function createFraudAlert(referralId, type, severity, detail) {
    const { data: ex } = await supabase.from('referral_fraud_alerts')
      .select('id').eq('referral_id', referralId).eq('type', type).eq('status', 'open').maybeSingle();
    if (ex) return;
    await supabase.from('referral_fraud_alerts')
      .insert({ referral_id: referralId, type, severity, detail });
  }

  // Comprobaciones en tiempo real al validar un código. NO bloquea: solo avisa.
  async function runFraudChecks({ referralId, referrerUserId, referredUserId, ip, deviceId }) {
    const cfg = await refConfig();
    const { data: ru } = await supabase.from('users').select('email').eq('id', referredUserId).maybeSingle();
    const email = (ru?.email || '').toLowerCase();
    const domain = email.split('@')[1] || '';

    // 1) Auto-referido por email (mismo correo que el referidor).
    const { data: rr } = await supabase.from('users').select('email').eq('id', referrerUserId).maybeSingle();
    if (email && rr?.email && email === rr.email.toLowerCase()) {
      await createFraudAlert(referralId, 'self_referral', 'high', { email });
    }

    // 2) Email temporal/desechable (lista + dominios bloqueados por config).
    const blocked = (cfg.referral_email_domains_blocked || '')
      .split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
    if (domain && (blocked.includes(domain) || DISPOSABLE_EMAIL_DOMAINS.includes(domain))) {
      await createFraudAlert(referralId, 'temp_email', 'medium', { domain });
    }

    // 3) Misma IP que otro referido (aviso, no bloqueo).
    if (ip) {
      const { data: sameIp } = await supabase.from('referrals')
        .select('id').eq('signup_ip', ip).neq('id', referralId).limit(1);
      if ((sameIp ?? []).length) await createFraudAlert(referralId, 'same_ip', 'low', { ip });

      // 4) Ráfaga de IP: más de N referidos desde la misma IP en 24h.
      const maxIp = parseInt(cfg.referral_max_per_ip_24h ?? '3', 10);
      const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
      const { count } = await supabase.from('referrals')
        .select('id', { count: 'exact', head: true }).eq('signup_ip', ip).gte('created_at', since);
      if ((count ?? 0) > maxIp) await createFraudAlert(referralId, 'ip_burst', 'high', { ip, count });
    }

    // 5) Dispositivo duplicado.
    if (deviceId) {
      const { data: sameDev } = await supabase.from('referrals')
        .select('id').eq('signup_device_id', deviceId).neq('id', referralId).limit(1);
      if ((sameDev ?? []).length) await createFraudAlert(referralId, 'device_dup', 'medium', { deviceId });
    }
  }

  // GET código del referidor + elegibilidad + definición de hitos.
  app.get('/api/v1/referrals/code', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    try {
      const cfg = await refConfig();
      if (cfg.referral_enabled !== 'true') return reply.send({ enabled: false });
      const eligible = await isReferralEligible(caller);
      const code = eligible ? await ensureReferralCode(caller.id) : null;
      return reply.send({
        enabled: true, eligible, code,
        milestones: milestonesFrom(cfg),
        annual_max_days: parseInt(cfg.referral_annual_max_days ?? '360', 10),
        validation_days: parseInt(cfg.referral_pay_window_days ?? '15', 10),
      });
    } catch (e) {
      request.log.error(e);
      return reply.code(500).send({ error: 'No se pudo obtener el código' });
    }
  });

  // POST registrar una compartición (límite diario) y devolver el código.
  app.post('/api/v1/referrals/share', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (!await isReferralEligible(caller)) {
      return reply.code(403).send({ error: 'Necesitas una suscripción activa para invitar' });
    }
    const channel = String((request.body ?? {}).channel ?? 'link');
    if (!['whatsapp', 'email', 'sms', 'link', 'other'].includes(channel)) {
      return reply.code(400).send({ error: 'Canal no válido' });
    }
    const cfg = await refConfig();
    const maxPerDay = parseInt(cfg.referral_max_shares_per_day ?? '20', 10);
    const since = new Date(); since.setHours(0, 0, 0, 0);
    const { count } = await supabase.from('referral_shares')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', caller.id).gte('created_at', since.toISOString());
    if ((count ?? 0) >= maxPerDay) {
      return reply.code(429).send({ error: `Límite de ${maxPerDay} invitaciones por día` });
    }
    const code = await ensureReferralCode(caller.id);
    await supabase.from('referral_shares').insert({ user_id: caller.id, code, channel });
    return reply.send({ ok: true, code, shares_today: (count ?? 0) + 1 });
  });

  // POST aplicar un código (el referido lo introduce tras crear su empresa).
  app.post('/api/v1/referrals/validate', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (!caller.tenant_id) return reply.code(400).send({ error: 'Crea tu empresa primero' });
    const code = String((request.body ?? {}).code ?? '').trim();
    if (!code) return reply.code(400).send({ error: 'Falta el código' });

    const { data: prev } = await supabase.from('referrals')
      .select('id').eq('referred_user_id', caller.id).maybeSingle();
    if (prev) return reply.code(409).send({ error: 'Ya has usado un código de invitación' });

    const { data: rc } = await supabase.from('referral_codes')
      .select('user_id, is_active').ilike('code', code).maybeSingle();
    if (!rc || rc.is_active === false) return reply.code(404).send({ error: 'Código no válido' });
    if (rc.user_id === caller.id) return reply.code(400).send({ error: 'No puedes invitarte a ti mismo' });

    const ip = (request.headers['x-forwarded-for'] || request.ip || '').toString().split(',')[0].trim();
    const device = String((request.body ?? {}).device_id ?? '');
    const { data: inserted, error } = await supabase.from('referrals').insert({
      referrer_user_id: rc.user_id, referred_user_id: caller.id,
      referred_tenant_id: caller.tenant_id, status: 'pending',
      signup_ip: ip || null, signup_device_id: device || null,
    }).select('id').single();
    if (error) {
      const dup = /duplicate|unique|23505/i.test(error.message || '');
      return reply.code(dup ? 409 : 400).send({ error: dup ? 'Ya has usado un código' : error.message });
    }
    // Anti-fraude (no bloquea: solo crea alertas para que el admin revise).
    try {
      await runFraudChecks({
        referralId: inserted.id, referrerUserId: rc.user_id, referredUserId: caller.id,
        ip, deviceId: device,
      });
    } catch (e) {
      request.log.error(`[referral-fraud] ${e.message}`);
    }
    return reply.send({ ok: true });
  });

  // GET historial de referidos del referidor.
  app.get('/api/v1/referrals/history', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    const { data, error } = await supabase.from('referrals')
      .select('id, status, created_at, validated_at, reverted_at, users:referred_user_id(email, name)')
      .eq('referrer_user_id', caller.id).order('created_at', { ascending: false });
    if (error) return reply.code(500).send({ error: error.message });
    return reply.send({ referrals: data ?? [] });
  });

  // GET progreso de hitos del referidor.
  app.get('/api/v1/referrals/progress', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    const cfg = await refConfig();
    const milestones = milestonesFrom(cfg);
    const { count } = await supabase.from('referrals')
      .select('id', { count: 'exact', head: true })
      .eq('referrer_user_id', caller.id).eq('status', 'valid');
    const valid = count ?? 0;
    const { data: claimed } = await supabase.from('referral_milestone_rewards')
      .select('milestone_level').eq('user_id', caller.id);
    const claimedLevels = new Set((claimed ?? []).map((c) => c.milestone_level));
    const { data: u } = await supabase.from('users')
      .select('referral_rewards_annual_days').eq('id', caller.id).maybeSingle();
    const next = milestones.find((m) => valid < m.required) ?? null;
    return reply.send({
      valid_referrals: valid,
      milestones: milestones.map((m) => ({ ...m, reached: valid >= m.required, claimed: claimedLevels.has(m.level) })),
      next: next ? { ...next, remaining: next.required - valid } : null,
      annual_days: u?.referral_rewards_annual_days ?? 0,
      annual_max: parseInt(cfg.referral_annual_max_days ?? '360', 10),
    });
  });

  // ============================================================
  // Referidos v2 — Iteración 5: panel de administración.
  // Listado con filtros, KPIs (conversión, CPA, K-factor), gestión de alertas,
  // edición de la config y escaneo anti-fraude bajo demanda. Solo admin.
  // ============================================================

  // Listado de referidos (filtros: status). Incluye correos y alertas abiertas.
  app.get('/api/v1/admin/referrals', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const status = request.query?.status;
    let q = supabase.from('referrals')
      .select('id, status, created_at, validated_at, reverted_at, signup_ip, signup_device_id, '
        + 'referrer:referrer_user_id(email, name), referred:referred_user_id(email, name)')
      .order('created_at', { ascending: false }).limit(500);
    if (['pending', 'valid', 'reverted', 'rejected'].includes(status)) q = q.eq('status', status);
    const { data: refs, error } = await q;
    if (error) return reply.code(500).send({ error: error.message });
    // Alertas abiertas, agrupadas por referral.
    const { data: alerts } = await supabase.from('referral_fraud_alerts')
      .select('id, referral_id, type, severity, status, created_at, detail')
      .eq('status', 'open');
    const byRef = {};
    for (const a of alerts ?? []) (byRef[a.referral_id] ??= []).push(a);
    const rows = (refs ?? []).map((r) => ({ ...r, alerts: byRef[r.id] ?? [] }));
    return reply.send({ referrals: rows, open_alerts: (alerts ?? []).length });
  });

  // KPIs del programa: conversión, CPA (días/adquisición), K-factor.
  app.get('/api/v1/admin/referrals/kpis', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const countWhere = async (col, val) => {
      const { count } = await supabase.from('referrals')
        .select('id', { count: 'exact', head: true }).eq(col, val);
      return count ?? 0;
    };
    const [pending, valid, reverted, rejected] = await Promise.all([
      countWhere('status', 'pending'), countWhere('status', 'valid'),
      countWhere('status', 'reverted'), countWhere('status', 'rejected'),
    ]);
    const total = pending + valid + reverted + rejected;
    const { count: sharesTotal } = await supabase.from('referral_shares')
      .select('id', { count: 'exact', head: true });
    // Distintos referidores con al menos un válido + total de días concedidos.
    const { data: validRows } = await supabase.from('referrals')
      .select('referrer_user_id').eq('status', 'valid').limit(5000);
    const distinctReferrers = new Set((validRows ?? []).map((r) => r.referrer_user_id)).size;
    const { data: rewardRows } = await supabase.from('referral_milestone_rewards')
      .select('days_awarded, credit_cents').limit(5000);
    const daysAwarded = (rewardRows ?? []).reduce((s, r) => s + (r.days_awarded ?? 0), 0);
    const milestonesAchieved = (rewardRows ?? []).length;
    // COSTE real del programa = suma de los CRÉDITOS Stripe concedidos por hitos
    // (N días de flota a la tarifa efectiva del cliente). Mismo criterio que Retos.
    const rewardCostEur = +((rewardRows ?? [])
      .reduce((s, r) => s + (r.credit_cents ?? 0), 0) / 100).toFixed(2);
    // Top referidores por nº de referidos VÁLIDOS (leaderboard de crecimiento).
    const validByReferrer = {};
    for (const r of validRows ?? []) {
      validByReferrer[r.referrer_user_id] = (validByReferrer[r.referrer_user_id] ?? 0) + 1;
    }
    const topIds = Object.entries(validByReferrer)
      .sort((a, b) => b[1] - a[1]).slice(0, 10);
    let topReferrers = [];
    if (topIds.length) {
      const { data: us } = await supabase.from('users')
        .select('id, name, email').in('id', topIds.map(([id]) => id));
      const nameById = {};
      for (const u of us ?? []) nameById[u.id] = u.name || u.email || '—';
      topReferrers = topIds.map(([id, count]) => ({ name: nameById[id] ?? '—', valid: count }));
    }
    const { count: openAlerts } = await supabase.from('referral_fraud_alerts')
      .select('id', { count: 'exact', head: true }).eq('status', 'open');
    // Pendientes de validar: en la cola de los 15 días (aún sin procesar).
    const { count: pendingValidation } = await supabase.from('referral_validation_queue')
      .select('id', { count: 'exact', head: true }).eq('processed', false);
    return reply.send({
      total, pending, valid, reverted, rejected,
      total_referrals: total,                                          // alias spec
      shares_total: sharesTotal ?? 0,
      pending_validation: pendingValidation ?? 0,                      // en cola de 15d
      distinct_referrers: distinctReferrers,
      conversion_rate: total ? +(valid / total).toFixed(3) : 0,        // válidos / total
      cpa_days: valid ? +(daysAwarded / valid).toFixed(1) : 0,         // días gratis por adquisición
      k_factor: distinctReferrers ? +(valid / distinctReferrers).toFixed(2) : 0, // válidos por referidor
      milestones_achieved: milestonesAchieved,
      days_awarded: daysAwarded,
      reward_cost_eur: rewardCostEur,                                  // € regalados
      top_referrers: topReferrers,                                     // leaderboard
      open_alerts: openAlerts ?? 0,
      fraud_alerts: openAlerts ?? 0,                                   // alias spec
    });
  });

  // Gestionar una alerta de fraude: resolver o descartar.
  app.post('/api/v1/admin/referrals/resolve/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const action = (request.body ?? {}).action;
    if (action !== 'resolve' && action !== 'dismiss') {
      return reply.code(400).send({ error: 'Acción no válida' });
    }
    const { error } = await supabase.from('referral_fraud_alerts')
      .update({ status: action === 'resolve' ? 'resolved' : 'dismissed', resolved_at: new Date().toISOString() })
      .eq('id', request.params.id);
    if (error) return reply.code(500).send({ error: error.message });
    return reply.send({ ok: true });
  });

  // Editar la configuración del programa (claves referral_* y challenge_*).
  app.put('/api/v1/admin/referrals/config', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const body = request.body ?? {};
    const SYSTEM_KEYS = new Set(['default_trial_days', 'retention_years']);
    const updates = Object.entries(body)
      .filter(([k]) => k.startsWith('referral_') || k.startsWith('challenge_') || k.startsWith('maintenance_') || SYSTEM_KEYS.has(k));
    if (!updates.length) return reply.code(400).send({ error: 'Nada que actualizar (claves referral_*/challenge_*/maintenance_*/sistema)' });
    for (const [key, value] of updates) {
      await supabase.from('system_config')
        .upsert({ key, value: String(value), updated_at: new Date().toISOString() }, { onConflict: 'key' });
    }
    await logAdminAction(request, g.caller.id, 'referral_config_update', 'config', 'system_config',
      { changes: Object.fromEntries(updates.map(([k, v]) => [k, String(v)])) });
    return reply.send({ ok: true, updated: updates.map(([k]) => k) });
  });

  // Escaneo anti-fraude bajo demanda (batch): ráfagas de IP y dispositivos
  // duplicados en las últimas 24h que aún no tengan alerta.
  app.post('/api/v1/admin/referrals/scan', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const cfg = await refConfig();
    const maxIp = parseInt(cfg.referral_max_per_ip_24h ?? '3', 10);
    const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
    const { data: recent } = await supabase.from('referrals')
      .select('id, signup_ip, signup_device_id, created_at').gte('created_at', since).limit(5000);
    const byIp = {};
    const byDev = {};
    for (const r of recent ?? []) {
      if (r.signup_ip) (byIp[r.signup_ip] ??= []).push(r.id);
      if (r.signup_device_id) (byDev[r.signup_device_id] ??= []).push(r.id);
    }
    let created = 0;
    for (const [ip, ids] of Object.entries(byIp)) {
      if (ids.length > maxIp) {
        for (const id of ids) { await createFraudAlert(id, 'ip_burst', 'high', { ip, count: ids.length }); created++; }
      }
    }
    for (const [dev, ids] of Object.entries(byDev)) {
      if (ids.length > 1) {
        for (const id of ids) { await createFraudAlert(id, 'device_dup', 'medium', { deviceId: dev }); created++; }
      }
    }
    return reply.send({ ok: true, scanned: (recent ?? []).length, alerts_created_or_kept: created });
  });

  // ============================================================
  // Loop #5 — Dashboard de Super Admin: referidos (listado con filtros,
  // detalle, bloqueo/desbloqueo, config con auditoría). Solo admin.
  // Nota de reconciliación: los estados reales del modelo son
  // pending|valid|reverted|rejected (el spec citaba clicked/registered/...);
  // aceptamos también el alias 'validated' -> 'valid'. La config vive en
  // system_config (no se crea una tabla paralela global_referral_config).
  // ============================================================
  const REF_STATUSES = ['pending', 'valid', 'reverted', 'rejected'];

  // Listado de referidos con filtros y paginación. Filtros: tenant_id, status
  // (CSV), date_from/date_to (created_at), channel (canal de compartición del
  // referidor), search (email/nombre de referidor o referido).
  app.get('/api/v1/admin/referrals/list', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const qp = request.query ?? {};
    const limit = Math.min(Math.max(parseInt(qp.limit ?? '25', 10) || 25, 1), 100);
    const offset = Math.max(parseInt(qp.offset ?? '0', 10) || 0, 0);

    let q = supabase.from('referrals')
      .select('id, status, created_at, validated_at, reverted_at, signup_ip, signup_device_id, '
        + 'referred_tenant_id, referrer:referrer_user_id(id, email, name), '
        + 'referred:referred_user_id(id, email, name), tenant:referred_tenant_id(name)',
        { count: 'exact' })
      .order('created_at', { ascending: false });

    if (qp.tenant_id) q = q.eq('referred_tenant_id', qp.tenant_id);
    if (qp.status) {
      const arr = String(qp.status).split(',').map((s) => s.trim())
        .map((s) => (s === 'validated' ? 'valid' : s))
        .filter((s) => REF_STATUSES.includes(s));
      if (arr.length) q = q.in('status', arr);
    }
    if (qp.date_from) q = q.gte('created_at', qp.date_from);
    if (qp.date_to) q = q.lte('created_at', qp.date_to);
    if (qp.channel) {
      const { data: sh } = await supabase.from('referral_shares')
        .select('user_id').eq('channel', qp.channel).limit(5000);
      const ids = [...new Set((sh ?? []).map((r) => r.user_id))];
      if (!ids.length) return reply.send({ referrals: [], total: 0, limit, offset });
      q = q.in('referrer_user_id', ids);
    }
    if (qp.search) {
      const term = `%${String(qp.search).trim()}%`;
      const { data: us } = await supabase.from('users')
        .select('id').or(`email.ilike.${term},name.ilike.${term}`).limit(5000);
      const ids = [...new Set((us ?? []).map((u) => u.id))];
      if (!ids.length) return reply.send({ referrals: [], total: 0, limit, offset });
      const list = ids.join(',');
      q = q.or(`referrer_user_id.in.(${list}),referred_user_id.in.(${list})`);
    }

    const { data: refs, count, error } = await q.range(offset, offset + limit - 1);
    if (error) return reply.code(500).send({ error: error.message });

    // Alertas abiertas por referral (para marcar sospechosos en la lista).
    const ids = (refs ?? []).map((r) => r.id);
    let byRef = {};
    if (ids.length) {
      const { data: alerts } = await supabase.from('referral_fraud_alerts')
        .select('id, referral_id, type, severity, status').eq('status', 'open').in('referral_id', ids);
      for (const a of alerts ?? []) (byRef[a.referral_id] ??= []).push(a);
    }
    const rows = (refs ?? []).map((r) => ({ ...r, alerts: byRef[r.id] ?? [] }));
    return reply.send({ referrals: rows, total: count ?? rows.length, limit, offset });
  });

  // Configuración de parámetros (lectura). Devuelve las claves referral_* y
  // challenge_* (el panel de admin edita ambas) y los hitos ya parseados.
  app.get('/api/v1/admin/referrals/config', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const cfg = await refConfig();
    const config = Object.fromEntries(Object.entries(cfg)
      .filter(([k]) => k.startsWith('referral_') || k.startsWith('challenge_')));
    return reply.send({ config, milestones: milestonesFrom(cfg) });
  });

  // Detalle de un referido: referidor, invitado, empresa, historial y fraude.
  app.get('/api/v1/admin/referrals/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { data: ref, error } = await supabase.from('referrals')
      .select('id, status, created_at, validated_at, reverted_at, signup_ip, signup_device_id, '
        + 'referred_tenant_id, referrer:referrer_user_id(id, email, name, tenant_id), '
        + 'referred:referred_user_id(id, email, name), '
        + 'tenant:referred_tenant_id(name, plan_id, subscription_status, created_at)')
      .eq('id', request.params.id).maybeSingle();
    if (error) return reply.code(500).send({ error: error.message });
    if (!ref) return reply.code(404).send({ error: 'Referido no encontrado' });

    // Hitos del referidor (ledger) + alertas de fraude de este referido.
    const referrerId = ref.referrer?.id;
    const [{ data: milestones }, { data: alerts }] = await Promise.all([
      referrerId
        ? supabase.from('referral_milestone_rewards')
            .select('milestone_level, required, days_awarded, awarded_at')
            .eq('user_id', referrerId).order('milestone_level', { ascending: true })
        : Promise.resolve({ data: [] }),
      supabase.from('referral_fraud_alerts')
        .select('id, type, severity, status, detail, created_at, resolved_at')
        .eq('referral_id', ref.id).order('created_at', { ascending: false }),
    ]);

    // Historial de eventos derivado de los timestamps.
    const events = [{ type: 'created', at: ref.created_at }];
    if (ref.validated_at) events.push({ type: 'validated', at: ref.validated_at });
    if (ref.reverted_at) events.push({ type: 'reverted', at: ref.reverted_at });
    for (const m of milestones ?? []) {
      events.push({ type: 'milestone', at: m.awarded_at, level: m.milestone_level, days: m.days_awarded });
    }
    events.sort((a, b) => new Date(a.at) - new Date(b.at));

    return reply.send({
      referral: ref,
      referrer_milestones: milestones ?? [],
      fraud: {
        signup_ip: ref.signup_ip,
        signup_device_id: ref.signup_device_id,
        alerts: alerts ?? [],
      },
      events,
    });
  });

  // Bloquear un referido por fraude: pasa a 'rejected' y se revierten sus
  // recompensas automáticamente (recompute revoca los hitos que ya no apliquen).
  app.put('/api/v1/admin/referrals/:id/block', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const reason = (request.body ?? {}).reason ?? null;
    const { data: ref } = await supabase.from('referrals')
      .select('id, referrer_user_id, status').eq('id', request.params.id).maybeSingle();
    if (!ref) return reply.code(404).send({ error: 'Referido no encontrado' });
    await supabase.from('referrals')
      .update({ status: 'rejected', reverted_at: new Date().toISOString() }).eq('id', ref.id);
    await recomputeReferrerMilestones(ref.referrer_user_id); // clawback automático
    await createFraudAlert(ref.id, 'manual_block', 'high', { reason, by: g.caller.id });
    await logAdminAction(request, g.caller.id, 'referral_block', 'referral', ref.id,
      { reason, previous_status: ref.status });
    return reply.send({ ok: true });
  });

  // Desbloquear un referido: restaura su estado (valid si llegó a validarse, o
  // pending) y recalcula hitos. Descarta sus alertas abiertas.
  app.put('/api/v1/admin/referrals/:id/unblock', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { data: ref } = await supabase.from('referrals')
      .select('id, referrer_user_id, status, validated_at').eq('id', request.params.id).maybeSingle();
    if (!ref) return reply.code(404).send({ error: 'Referido no encontrado' });
    const restored = ref.validated_at ? 'valid' : 'pending';
    await supabase.from('referrals')
      .update({ status: restored, reverted_at: null }).eq('id', ref.id);
    await recomputeReferrerMilestones(ref.referrer_user_id);
    await supabase.from('referral_fraud_alerts')
      .update({ status: 'dismissed', resolved_at: new Date().toISOString() })
      .eq('referral_id', ref.id).eq('status', 'open');
    await logAdminAction(request, g.caller.id, 'referral_unblock', 'referral', ref.id,
      { restored_status: restored, previous_status: ref.status });
    return reply.send({ ok: true, status: restored });
  });
}
