// ============================================================
// TaxiCount - Dashboard financiero (admin). Fase B del troceig — el núcleo.
// Fuente de verdad = STRIPE (se lee en vivo). Endpoints: /admin/overview (visión
// global de la plataforma), /admin/daily-metrics (pols diari) y /admin/billing
// (MRR/comisiones/ingresos). Incluye TODOS los helpers financieros y sus cachés
// (60s): dayBounds, sumPaidInvoices, sumRefunds, readGlobalRevenue, readGlobalFees,
// readTenantRevenue, readMrr. Solo admin, solo lectura.
//
// PROTECCIÓN DE DATOS: son cifras de PLATAFORMA (lo que cobra TaxiCount), NUNCA las
// finanzas internas de los clientes. Devuelve { readGlobalRevenue, readTenantRevenue }
// porque los comparten retos.js (summary) y companies.js (ficha de empresa).
// ============================================================

export function registerFinancialRoutes(app, { supabase, stripe, adminGuard, probeDb, log }) {
  // ---- Ingresos REALES cobrados (fuente de verdad = Stripe). Suma las facturas
  // pagadas: `paid` = neto cobrado (lo que han pagado los clientes), `discount` =
  // total descontado con cupones. En céntimos. El global se cachea 60 s para no
  // listar Stripe en cada carga del panel.
  function dayBounds() {
    const t = new Date(); t.setUTCHours(0, 0, 0, 0);
    const startTodayS = Math.floor(t.getTime() / 1000);
    const d = new Date();
    const startMonthS = Math.floor(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), 1) / 1000);
    return { startTodayS, startMonthS };
  }

  async function sumPaidInvoices(params) {
    let paid = 0;
    let discount = 0;
    let count = 0;
    let currency = 'eur';
    let paidToday = 0;
    let countToday = 0;
    let paidMtd = 0;
    const byCustomer = {}; // customerId -> total pagado (céntimos), para el módulo de facturación
    const { startTodayS, startMonthS } = dayBounds();
    for await (const inv of stripe.invoices.list({ status: 'paid', limit: 100, ...params })) {
      const amt = inv.amount_paid || 0;
      paid += amt;
      for (const d of inv.total_discount_amounts || []) discount += d.amount || 0;
      count += 1;
      if (inv.currency) currency = inv.currency;
      const cust = typeof inv.customer === 'string' ? inv.customer : inv.customer?.id;
      if (cust) byCustomer[cust] = (byCustomer[cust] || 0) + amt;
      const at = inv.status_transitions?.paid_at ?? inv.created ?? 0;
      if (at >= startTodayS) { paidToday += amt; countToday += 1; }
      if (at >= startMonthS) paidMtd += amt;
    }
    return { paid, discount, count, currency, paidToday, countToday, paidMtd, byCustomer };
  }

  // Total DEVUELTO (reembolsos). Las facturas pagadas no cambian al reembolsar,
  // así que se mira aparte: global vía refunds.list; por cliente vía sus charges
  // (refunds no se puede filtrar por customer).
  async function sumRefunds(customerId) {
    let refunded = 0;
    let refundedToday = 0;
    const { startTodayS } = dayBounds();
    if (customerId) {
      for await (const ch of stripe.charges.list({ customer: customerId, limit: 100 })) {
        refunded += ch.amount_refunded || 0;
      }
    } else {
      for await (const r of stripe.refunds.list({ limit: 100 })) {
        if (r.status === 'failed' || r.status === 'canceled') continue;
        refunded += r.amount || 0;
        if ((r.created ?? 0) >= startTodayS) refundedToday += r.amount || 0;
      }
    }
    return { refunded, refundedToday };
  }

  let _revenueCache = null; // { at, data }
  async function readGlobalRevenue() {
    if (!stripe) return null;
    if (_revenueCache && Date.now() - _revenueCache.at < 60000) return _revenueCache.data;
    try {
      const data = await sumPaidInvoices({});
      const ref = await sumRefunds(null);
      data.refunded = ref.refunded;
      data.refundedToday = ref.refundedToday;
      _revenueCache = { at: Date.now(), data };
      return data;
    } catch (e) {
      log.warn(`[revenue] global: ${e.message}`);
      return _revenueCache?.data ?? null;
    }
  }

  // Comisiones REALES de Stripe (céntimos), de las balance transactions (campo
  // `fee` de los cargos), por hoy / mes (MTD) / total. Es un COSTE: el MRR/ARR se
  // dejan brutos (estándar), pero la CAJA muestra bruto − comisión = neto (payout).
  let _feesCache = null;
  async function readGlobalFees() {
    if (!stripe) return { feeToday: 0, feeMtd: 0, feeTotal: 0 };
    if (_feesCache && Date.now() - _feesCache.at < 60000) return _feesCache.data;
    try {
      const { startTodayS, startMonthS } = dayBounds();
      let feeToday = 0; let feeMtd = 0; let feeTotal = 0;
      for await (const bt of stripe.balanceTransactions.list({ limit: 100 })) {
        if (bt.type !== 'charge' && bt.type !== 'payment') continue;
        const fee = bt.fee || 0;
        feeTotal += fee;
        const at = bt.created ?? 0;
        if (at >= startTodayS) feeToday += fee;
        if (at >= startMonthS) feeMtd += fee;
      }
      const data = { feeToday, feeMtd, feeTotal };
      _feesCache = { at: Date.now(), data };
      return data;
    } catch (e) {
      log.warn(`[fees] global: ${e.message}`);
      return _feesCache?.data ?? { feeToday: 0, feeMtd: 0, feeTotal: 0 };
    }
  }

  async function readTenantRevenue(customerId) {
    if (!stripe || !customerId) return { paid: 0, discount: 0, count: 0, refunded: 0, currency: 'eur' };
    try {
      const data = await sumPaidInvoices({ customer: customerId });
      data.refunded = (await sumRefunds(customerId)).refunded;
      return data;
    } catch (e) {
      log.warn(`[revenue] tenant: ${e.message}`);
      return { paid: 0, discount: 0, count: 0, refunded: 0, currency: 'eur' };
    }
  }

  // MRR REAL (Monthly Recurring Revenue): NO es una proyección, es la foto AHORA
  // del ingreso recurrente. Se lee de las subscripciones vivas de Stripe (active +
  // past_due: siguen suscritas aunque falle el cobro) sumando, por item,
  // unit_amount×cantidad normalizado a mes (anual /12). MRR bruto (antes de
  // cupones). unit_amount puede venir null -> fallbacks como en el ajuste de
  // asientos. ARR = MRR×12. Caché 60 s.
  let _mrrCache = null;
  async function readMrr() {
    if (!stripe) return null;
    if (_mrrCache && Date.now() - _mrrCache.at < 60000) return _mrrCache.data;
    try {
      let mrr = 0; // céntimos/mes
      let subs = 0;
      for (const status of ['active', 'past_due']) {
        for await (const s of stripe.subscriptions.list(
            { status, limit: 100, expand: ['data.items.data.price'] })) {
          subs += 1;
          for (const it of s.items?.data ?? []) {
            const p = it.price || {};
            let unit = p.unit_amount;
            if (unit == null && p.unit_amount_decimal != null) unit = Math.round(Number(p.unit_amount_decimal));
            const interval = p.recurring?.interval || 'month';
            if (unit == null || Number.isNaN(unit)) unit = interval === 'year' ? 3000 : 300;
            const qty = it.quantity ?? 1;
            mrr += interval === 'year' ? (unit * qty) / 12 : unit * qty;
          }
        }
      }
      const data = { mrr: Math.round(mrr), subs };
      _mrrCache = { at: Date.now(), data };
      return data;
    } catch (e) {
      log.warn(`[mrr] ${e.message}`);
      return _mrrCache?.data ?? null;
    }
  }

  // Resumen de todas las empresas: datos + nº de usuarios + incidencias abiertas.
  app.get('/api/v1/admin/overview', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });

    const { data: tenants, error } = await supabase
      .from('tenants')
      .select('id, name, solo, subscription_status, plan_id, trial_ends_at, created_at')
      .order('created_at', { ascending: false });
    if (error) return reply.code(500).send({ error: error.message });

    const { data: users } = await supabase.from('users').select('id, tenant_id');
    const { data: openInc } = await supabase
      .from('incidents')
      .select('id, tenant_id')
      .eq('status', 'abierta');

    const usersByTenant = {};
    for (const u of users || []) usersByTenant[u.tenant_id] = (usersByTenant[u.tenant_id] || 0) + 1;
    const incByTenant = {};
    for (const i of openInc || []) incByTenant[i.tenant_id] = (incByTenant[i.tenant_id] || 0) + 1;

    const rows = (tenants || []).map((t) => ({
      ...t,
      users_count: usersByTenant[t.id] || 0,
      open_incidents: incByTenant[t.id] || 0,
    }));

    // ---- Panel rediseñado (Fase 1): KPIs, pendientes, bandeja de trabajo,
    // estado de crons y salud de la plataforma. Campos NUEVOS: la UI antigua
    // sigue leyendo tenants/totals sin cambios.
    const now = Date.now();
    const dayMs = 86400000;
    const paying = rows.filter((t) => t.subscription_status === 'active' || t.subscription_status === 'past_due');
    const payingIds = new Set(paying.map((t) => t.id));
    const pastDue = rows.filter((t) => t.subscription_status === 'past_due');
    const inTrial = rows.filter((t) => !payingIds.has(t.id) && t.trial_ends_at && new Date(t.trial_ends_at).getTime() > now);
    const trialSoon = inTrial.filter((t) => new Date(t.trial_ends_at).getTime() - now <= 5 * dayMs);

    // Conductores y MRR estimado (annual_price_paid/12 de los activos de pago).
    const { data: drivers } = await supabase.from('users')
      .select('tenant_id, active, annual_price_paid').eq('role', 'driver');
    let driversTotal = 0;
    let driversActive = 0;
    for (const d of drivers ?? []) {
      driversTotal++;
      if (d.active !== false) driversActive++;
    }

    // Pendientes por tipo (acotados; solo lo abierto/no resuelto).
    const { data: refAlerts } = await supabase.from('referral_fraud_alerts')
      .select('id, type, detail, severity, created_at').is('resolved_at', null)
      .order('created_at', { ascending: false }).limit(100);
    const { data: genAlerts } = await supabase.from('fraud_alerts')
      .select('id, alert_type, description, severity, tenant_id, created_at').is('resolved_at', null)
      .order('created_at', { ascending: false }).limit(100);
    const { data: tickets } = await supabase.from('incidents')
      .select('id, body, created_at, tenant_id, tenants(name)')
      .eq('kind', 'app').eq('status', 'abierta')
      .order('created_at', { ascending: true }).limit(100);
    const { data: suspicious } = await supabase.from('challenge_claims')
      .select('id, tenant_id, user_id, created_at, users:user_id(name, email), tenants:tenant_id(name)')
      .eq('suspicious', true).eq('status', 'rewarded').is('reward_redeemed_at', null)
      .order('created_at', { ascending: false }).limit(100);

    const fraudOpen = (refAlerts?.length ?? 0) + (genAlerts?.length ?? 0);
    const ticketsOld = (tickets ?? []).filter((i) => now - new Date(i.created_at).getTime() > dayMs).length;

    // Bandeja de trabajo: lo accionable de todos los módulos, priorizado.
    const inbox = [];
    for (const a of refAlerts ?? []) {
      inbox.push({ type: 'fraud', id: a.id, title: a.detail || a.type || 'Alerta de referidos',
        subtitle: `referidos · ${a.severity ?? ''}`.trim(), created_at: a.created_at, module: 'referrals' });
    }
    for (const a of genAlerts ?? []) {
      inbox.push({ type: 'fraud', id: a.id, title: a.description || a.alert_type || 'Alerta de fraude',
        subtitle: a.severity ?? '', tenant_id: a.tenant_id, created_at: a.created_at, module: 'referrals' });
    }
    for (const c of suspicious ?? []) {
      inbox.push({ type: 'challenge', id: c.id,
        title: `Reto sospechoso de ${c.users?.name || c.users?.email || 'conductor'}`,
        subtitle: c.tenants?.name ?? '', tenant_id: c.tenant_id, created_at: c.created_at, module: 'challenges' });
    }
    for (const i of tickets ?? []) {
      inbox.push({ type: 'ticket', id: i.id, title: (i.body || '').slice(0, 90),
        subtitle: i.tenants?.name ?? '', tenant_id: i.tenant_id, created_at: i.created_at, module: 'incidents' });
    }
    for (const t of trialSoon) {
      const days = Math.max(0, Math.ceil((new Date(t.trial_ends_at).getTime() - now) / dayMs));
      inbox.push({ type: 'trial', id: t.id, title: `La prueba de ${t.name} acaba en ${days} día${days === 1 ? '' : 's'}`,
        subtitle: `${t.users_count} usuarios`, tenant_id: t.id, created_at: t.trial_ends_at, module: 'company' });
    }
    const prio = { fraud: 0, challenge: 1, ticket: 2, trial: 3 };
    inbox.sort((a, b) => (prio[a.type] - prio[b.type])
      || (new Date(a.created_at).getTime() - new Date(b.created_at).getTime()));

    // Última ejecución de cada cron (markCronRun) para los semáforos.
    const { data: cronRows } = await supabase.from('system_config')
      .select('key, value').like('key', 'cron_last_%');
    const crons = {};
    for (const r of cronRows ?? []) crons[r.key.replace('cron_last_', '')] = r.value;

    // Estado de los servicios externos (whisper/openai) para sus semáforos.
    // Valor guardado: "ok|<iso>" o "err|<iso>". ok=false solo si el último
    // intento falló (así la inactividad no da falsos rojos).
    const { data: svcRows } = await supabase.from('system_config')
      .select('key, value').like('key', 'svc_%');
    const services = {};
    for (const r of svcRows ?? []) {
      const [status, at] = String(r.value || '').split('|');
      // Error antiguo (>24 h) deja de alertar (mismo criterio que los semáforos).
      const recentErr = status === 'err' && at
        && (now - new Date(at).getTime() < 24 * 60 * 60 * 1000);
      services[r.key.replace('svc_', '')] = { ok: !recentErr, at: at || null };
    }
    // Push sin configurar = apagado a propósito, no avería (ignora errores viejos).
    if (!pushEnabled()) services.push = { ok: true, at: null, off: true };
    const cronStale = ['challenge_credits', 'referral_validations'].some((k) => {
      const v = crons[k];
      return !v || now - new Date(v).getTime() > 2 * dayMs;
    });

    // Eventos de Stripe sin aplicar (bandeja webhook_events): 0 = sano. Cuenta los
    // rotos ('error'/'dead') y los atascados ('received' > 10 min = backlog async).
    // Best-effort (la tabla puede no existir aún en prod → se trata como 0).
    let webhookErrors = 0;
    try {
      const stuckCutoff = new Date(now - 10 * 60 * 1000).toISOString();
      const [brokenRes, stuckRes] = await Promise.all([
        supabase.from('webhook_events').select('event_id', { count: 'exact', head: true })
          .in('status', ['error', 'dead']),
        supabase.from('webhook_events').select('event_id', { count: 'exact', head: true })
          .eq('status', 'received').lt('received_at', stuckCutoff),
      ]);
      webhookErrors = (brokenRes.count ?? 0) + (stuckRes.count ?? 0);
    } catch { /* tabla webhook_events aún no desplegada */ }

    // Salud 0-100: penaliza fraude abierto, tickets envejecidos, impagos,
    // crons parados y errores nuevos. Transparente y estable.
    let health = 100;
    health -= Math.min(30, fraudOpen * 15);
    health -= Math.min(15, ticketsOld * 5);
    health -= pastDue.length > 0 ? 10 : 0;
    health -= cronStale ? 10 : 0;
    health -= webhookErrors > 0 ? 10 : 0; // cobros/cancelaciones sin reflejar
    health = Math.max(0, Math.round(health));

    // Ingresos reales cobrados (Stripe): total facturado neto + lo descontado con
    // cupones. En euros. Best-effort: si Stripe no responde, revenue = null.
    const revenue = await readGlobalRevenue();

    // Total histórico de carreras (income), para el KPI de plataforma (portada)
    // y la cabecera de Empresas. Best-effort (recuento, sin importes).
    let ridesTotal = 0;
    try {
      const { count } = await supabase.from('transactions')
        .select('id', { count: 'exact', head: true }).eq('type', 'income');
      ridesTotal = count ?? 0;
    } catch { /* best-effort */ }

    // MRR REAL (Stripe, cacheado 60s) + churn, para el resumen de portada (no el
    // estimado). Churn = cancelaciones / (activas + canceladas).
    const mrrReal = await readMrr();
    const activeCount = rows.filter((t) => t.subscription_status === 'active').length;
    const canceledCount = rows.filter((t) => t.subscription_status === 'canceled').length;
    const churn = (activeCount + canceledCount) > 0
      ? Number(((canceledCount / (activeCount + canceledCount)) * 100).toFixed(1)) : 0;

    return reply.send({
      tenants: rows,
      totals: {
        tenants: rows.length,
        users: (users || []).length,
        open_incidents: (openInc || []).length,
      },
      kpis: {
        tenants: rows.length,
        paying: paying.length,
        trialing: inTrial.length,
        past_due: pastDue.length,
        drivers_total: driversTotal,
        drivers_active: driversActive,
        mrr: Number(((mrrReal?.mrr ?? 0) / 100).toFixed(2)),
        mrr_subs: mrrReal?.subs ?? 0,
        churn,
        rides_total: ridesTotal,
      },
      revenue: revenue ? {
        // Neto REAL en caja: facturado pagado menos lo devuelto (reembolsos).
        paid_total: Number(((revenue.paid - (revenue.refunded || 0)) / 100).toFixed(2)),
        coupon_total: Number((revenue.discount / 100).toFixed(2)),
        refund_total: Number(((revenue.refunded || 0) / 100).toFixed(2)),
        invoices: revenue.count,
        currency: revenue.currency,
      } : null,
      pending: {
        fraud: fraudOpen,
        challenges: suspicious?.length ?? 0,
        tickets: tickets?.length ?? 0,
        trials_ending: trialSoon.length,
      },
      inbox: inbox.slice(0, 12),
      crons,
      services,
      webhook_errors: webhookErrors,
      database: await probeDb(),
      health,
    });
  });

  // ---- Pols diari: métricas agregadas de la plataforma. PROTECCIÓN DE DATOS: el
  // admin NO ve el dinero de las carreras de los clientes; aquí solo hay NÚMEROS
  // (recuentos) y, en €, únicamente NUESTROS ingresos (suscripciones de Stripe).
  app.get('/api/v1/admin/daily-metrics', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });

    const startToday = new Date(); startToday.setUTCHours(0, 0, 0, 0);
    const todayIso = startToday.toISOString();
    const todayDate = todayIso.slice(0, 10);
    const weekAgoIso = new Date(Date.now() - 7 * 86400000).toISOString();
    const now = Date.now();
    const dayMs = 86400000;

    const countSince = async (table, col, sinceIso, extra) => {
      let q = supabase.from(table).select('id', { count: 'exact', head: true }).gte(col, sinceIso);
      if (extra) q = extra(q);
      const { count } = await q;
      return count || 0;
    };

    // --- Uso (recuentos, sin importes) ---
    const ridesToday = await countSince('transactions', 'created_at', todayIso, (q) => q.eq('type', 'income'));
    // DAU: usuarios distintos con actividad hoy (carreras/gastos + lecturas km).
    const [{ data: txU }, { data: odU }] = await Promise.all([
      supabase.from('transactions').select('user_id').gte('created_at', todayIso).limit(5000),
      supabase.from('odometer_readings').select('user_id').gte('taken_at', todayIso).limit(5000),
    ]);
    const dau = new Set([...(txU || []), ...(odU || [])].map((r) => r.user_id).filter(Boolean)).size;
    // Transcripciones de voz hoy (suma del contador diario por usuario).
    const { data: trRows } = await supabase.from('users')
      .select('daily_transcription_count').eq('transcription_count_date', todayDate);
    const transcriptionsToday = (trRows || []).reduce((s, r) => s + (r.daily_transcription_count || 0), 0);

    // --- Crecimiento ---
    const newCompaniesToday = await countSince('tenants', 'created_at', todayIso, (q) => q.is('closed_at', null));
    const newDriversToday = await countSince('users', 'created_at', todayIso, (q) => q.eq('role', 'driver'));

    // --- Producto: activación y riesgo (a partir de tenants + actividad) ---
    const { data: tenants } = await supabase.from('tenants')
      .select('id, subscription_status, trial_ends_at, closed_at');
    const live = (tenants || []).filter((t) => !t.closed_at);
    const trialing = live.filter((t) => t.subscription_status === 'trialing'
      && t.trial_ends_at && new Date(t.trial_ends_at).getTime() > now);
    const paying = live.filter((t) => t.subscription_status === 'active' || t.subscription_status === 'past_due');
    const trialsEnding = trialing.filter((t) => new Date(t.trial_ends_at).getTime() - now <= 5 * dayMs).length;
    // Tenants con alguna carrera (activación) y con carrera en 7 días (retención).
    const [{ data: everTx }, { data: recentTx }] = await Promise.all([
      supabase.from('transactions').select('tenant_id').limit(20000),
      supabase.from('transactions').select('tenant_id').gte('created_at', weekAgoIso).limit(20000),
    ]);
    const everSet = new Set((everTx || []).map((r) => r.tenant_id));
    const recentSet = new Set((recentTx || []).map((r) => r.tenant_id));
    const activated = trialing.filter((t) => everSet.has(t.id)).length;
    const activationRate = trialing.length ? Math.round((activated / trialing.length) * 100) : null;
    const atRisk = paying.filter((t) => !recentSet.has(t.id)).length;

    // --- Soporte ---
    const { count: openTickets } = await supabase.from('incidents')
      .select('id', { count: 'exact', head: true }).eq('kind', 'app').eq('status', 'abierta');

    // --- Negocio (€ NUESTROS: Stripe) ---
    const rev = await readGlobalRevenue();
    const business = rev ? {
      revenue_today: Number(((rev.paidToday || 0) / 100).toFixed(2)),
      revenue_mtd: Number(((rev.paidMtd || 0) / 100).toFixed(2)),
      payments_today: rev.countToday || 0,
      refunds_today: Number(((rev.refundedToday || 0) / 100).toFixed(2)),
    } : null;

    return reply.send({
      day: todayDate,
      business,
      usage: { rides_today: ridesToday, dau, transcriptions_today: transcriptionsToday },
      growth: { new_companies_today: newCompaniesToday, new_drivers_today: newDriversToday, trials_ending: trialsEnding },
      product: { activation_rate: activationRate, activated, trialing: trialing.length, at_risk: atRisk, paying: paying.length },
      support: { open_tickets: openTickets || 0 },
    });
  });

  // Módulo Facturación del panel (Fase 3): visión de negocio lado TaxiCount.
  // MRR estimado por empresa (annual_price_paid/12 de conductores activos),
  // impagados, pruebas próximas a vencer y ahorro total repartido. NUNCA
  // finanzas internas de los clientes (protección de datos).
  app.get('/api/v1/admin/billing', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const now = Date.now();
    const dayMs = 86400000;

    const [{ data: tenants }, { data: drivers }, { data: exts }, { data: milestones }] = await Promise.all([
      supabase.from('tenants')
        .select('id, name, subscription_status, trial_ends_at, drivers_limit, created_at, stripe_customer_id')
        .order('created_at', { ascending: false }),
      supabase.from('users').select('id, tenant_id, active, annual_price_paid, role'),
      supabase.from('subscription_extensions').select('tenant_id, credit_cents').eq('extension_type', 'challenge'),
      supabase.from('referral_milestone_rewards').select('user_id, credit_cents'),
    ]);

    // Crédito de recompensas (retos por tenant, referidos por owner -> tenant), en
    // céntimos: lo que hemos REGALADO como descuento Stripe (no días de trial).
    const ownerTenant = {};
    const seatsByTenant = {};
    for (const u of drivers ?? []) {
      if (u.role === 'owner') ownerTenant[u.id] = u.tenant_id;
      if (u.role === 'driver' && u.active !== false) {
        (seatsByTenant[u.tenant_id] ||= []).push(Number(u.annual_price_paid ?? 15));
      }
    }
    const centsByTenant = {};
    let centsCh = 0;
    let centsRef = 0;
    for (const e of exts ?? []) {
      const c = e.credit_cents ?? 0;
      centsByTenant[e.tenant_id] = (centsByTenant[e.tenant_id] ?? 0) + c;
      centsCh += c;
    }
    for (const m of milestones ?? []) {
      const tid = ownerTenant[m.user_id];
      const c = m.credit_cents ?? 0;
      if (tid) centsByTenant[tid] = (centsByTenant[tid] ?? 0) + c;
      centsRef += c;
    }

    // Dinero REAL pagado por cada empresa (Stripe), agrupando las facturas
    // pagadas por cliente. Sustituye al MRR estimado (proyección por asientos
    // activos): aquí solo hay lo que se ha cobrado de verdad.
    const rev = await readGlobalRevenue();
    const mrrData = await readMrr();
    const fees = await readGlobalFees();
    const byCustomer = rev?.byCustomer ?? {};
    const rows = (tenants ?? []).map((t) => {
      const paying = t.subscription_status === 'active' || t.subscription_status === 'past_due';
      const activeSeats = (seatsByTenant[t.id] ?? []).length;
      const paidCents = t.stripe_customer_id ? (byCustomer[t.stripe_customer_id] || 0) : 0;
      const trialEnds = t.trial_ends_at ? new Date(t.trial_ends_at).getTime() : null;
      const trialDays = (!paying && trialEnds && trialEnds > now)
        ? Math.ceil((trialEnds - now) / dayMs) : null;
      return {
        id: t.id, name: t.name, status: t.subscription_status,
        paid_seats: t.drivers_limit,          // asientos PAGADOS (cantidad Stripe)
        active_seats: activeSeats,             // asientos ocupados (conductores activos)
        paid_total: Number((paidCents / 100).toFixed(2)), // € reales pagados (acumulado)
        trial_days_left: trialDays,
        reward_credit_eur: Number(((centsByTenant[t.id] ?? 0) / 100).toFixed(2)),
      };
    });

    const payingCount = rows.filter((r) => r.status === 'active').length;
    const canceled = rows.filter((r) => r.status === 'canceled').length;
    // Churn = cancelaciones / (activas + canceladas).
    const churn = (payingCount + canceled) > 0
      ? +((canceled / (payingCount + canceled)) * 100).toFixed(1) : 0;
    // Salud recurrente: MRR real (foto ahora, de las subs vivas de Stripe),
    // ARR = MRR×12, ARPA = MRR / empresas que pagan.
    const mrr = Number(((mrrData?.mrr ?? 0) / 100).toFixed(2));
    const arr = Number((mrr * 12).toFixed(2));
    const arpa = payingCount > 0 ? +(mrr / payingCount).toFixed(2) : 0;
    // Caja REAL cobrada (Stripe) por periodo: hoy, este mes (MTD) y total neto.
    const cashToday = Number(((rev?.paidToday ?? 0) / 100).toFixed(2));
    const cashMtd = Number(((rev?.paidMtd ?? 0) / 100).toFixed(2));
    const cashTotal = Number((((rev?.paid ?? 0) - (rev?.refunded ?? 0)) / 100).toFixed(2));
    // Comisiones REALES de Stripe (coste), por periodo. La UI muestra bruto − comisión = neto.
    const feeToday = Number(((fees?.feeToday ?? 0) / 100).toFixed(2));
    const feeMtd = Number(((fees?.feeMtd ?? 0) / 100).toFixed(2));
    const feeTotal = Number(((fees?.feeTotal ?? 0) / 100).toFixed(2));

    return reply.send({
      totals: {
        mrr, arr, arpa,              // salud recurrente (€/mes, €/año, €/empresa·mes)
        mrr_subs: mrrData?.subs ?? 0, // nº de subscripciones que forman el MRR
        cash_today: cashToday,       // € cobrados hoy (bruto)
        cash_mtd: cashMtd,           // € cobrados este mes (bruto)
        cash_total: cashTotal,       // € cobrados neto de reembolsos (acumulado)
        fee_today: feeToday,         // comisión Stripe hoy
        fee_mtd: feeMtd,             // comisión Stripe este mes
        fee_total: feeTotal,         // comisión Stripe total
        paying: payingCount,
        past_due: rows.filter((r) => r.status === 'past_due').length,
        trialing: rows.filter((r) => r.trial_days_left != null).length,
        canceled,
        churn, // %
        reward_credit_total_eur: Number(((centsCh + centsRef) / 100).toFixed(2)),
      },
      past_due: rows.filter((r) => r.status === 'past_due'),
      trials: rows.filter((r) => r.trial_days_left != null)
        .sort((a, b) => a.trial_days_left - b.trial_days_left),
      paying: rows.filter((r) => r.status === 'active')
        .sort((a, b) => b.paid_total - a.paid_total),
    });
  });

  return { readGlobalRevenue, readTenantRevenue };
}
