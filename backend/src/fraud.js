// ============================================================
// TaxiCount - Centro de fraude (Loop #5). Fase B del troceig.
// Plugin de rutas: visor unificado de alertas de fraude que combina
// referral_fraud_alerts (anti-fraude de referidos) + fraud_alerts (genéricas):
// lista con filtros, detalle y resolución. El id unificado es "<source>:<uuid>".
// Sin cambio de comportamiento; deps del closure inyectadas por parámetro.
// NOTA: el escaneo/config anti-fraude de referidos (batch) NO está aquí; vive
// con el dominio Referidos porque está acoplado a él.
// ============================================================

export function registerFraudRoutes(app, { supabase, adminGuard, logAdminAction }) {
  // ============================================================
  // Loop #5 — Centro de fraude (unifica referral_fraud_alerts + fraud_alerts)
  // y logs de auditoría. Solo admin. El id unificado es "<source>:<uuid>".
  // ============================================================

  // Normaliza una alerta de referidos al formato genérico del centro de fraude.
  const mapReferralAlert = (a) => ({
    alert_id: `referral:${a.id}`, source: 'referral', id: a.id,
    alert_type: a.type, severity: a.severity, status: a.status,
    description: null, evidence: a.detail ?? null,
    referral_id: a.referral_id, tenant_id: null, user_id: null,
    created_at: a.created_at, resolved_at: a.resolved_at ?? null,
  });
  const mapGenericAlert = (a) => ({
    alert_id: `fraud:${a.id}`, source: 'fraud', id: a.id,
    alert_type: a.alert_type, severity: a.severity, status: a.status,
    description: a.description, evidence: a.evidence ?? null,
    referral_id: null, tenant_id: a.tenant_id, user_id: a.user_id,
    resolution_notes: a.resolution_notes ?? null,
    created_at: a.created_at, resolved_at: a.resolved_at ?? null,
  });

  // Lista unificada de alertas. Filtros: ?severity= &status= &type= &source=.
  app.get('/api/v1/admin/fraud/alerts', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const qp = request.query ?? {};
    const limit = Math.min(Math.max(parseInt(qp.limit ?? '50', 10) || 50, 1), 200);
    const offset = Math.max(parseInt(qp.offset ?? '0', 10) || 0, 0);
    const wantReferral = !qp.source || qp.source === 'referral';
    const wantGeneric = !qp.source || qp.source === 'fraud';

    let items = [];
    if (wantReferral) {
      let rq = supabase.from('referral_fraud_alerts')
        .select('id, referral_id, type, severity, status, detail, created_at, resolved_at')
        .order('created_at', { ascending: false }).limit(1000);
      if (qp.severity) rq = rq.eq('severity', qp.severity);
      if (qp.status) rq = rq.eq('status', qp.status);
      if (qp.type) rq = rq.eq('type', qp.type);
      const { data } = await rq;
      items = items.concat((data ?? []).map(mapReferralAlert));
    }
    if (wantGeneric) {
      let fq = supabase.from('fraud_alerts')
        .select('id, tenant_id, user_id, alert_type, severity, description, evidence, status, '
          + 'resolution_notes, created_at, resolved_at')
        .order('created_at', { ascending: false }).limit(1000);
      if (qp.severity) fq = fq.eq('severity', qp.severity);
      if (qp.status) fq = fq.eq('status', qp.status);
      if (qp.type) fq = fq.eq('alert_type', qp.type);
      const { data } = await fq;
      items = items.concat((data ?? []).map(mapGenericAlert));
    }
    items.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
    const total = items.length;
    return reply.send({ alerts: items.slice(offset, offset + limit), total, limit, offset });
  });

  // Detalle de una alerta unificada ("<source>:<uuid>").
  app.get('/api/v1/admin/fraud/alerts/:aid', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const [source, id] = String(request.params.aid).split(':');
    if (source === 'referral') {
      const { data: a } = await supabase.from('referral_fraud_alerts')
        .select('id, referral_id, type, severity, status, detail, created_at, resolved_at')
        .eq('id', id).maybeSingle();
      if (!a) return reply.code(404).send({ error: 'Alerta no encontrada' });
      return reply.send({ alert: mapReferralAlert(a) });
    }
    if (source === 'fraud') {
      const { data: a } = await supabase.from('fraud_alerts')
        .select('id, tenant_id, user_id, alert_type, severity, description, evidence, status, '
          + 'resolution_notes, resolved_by, created_at, resolved_at')
        .eq('id', id).maybeSingle();
      if (!a) return reply.code(404).send({ error: 'Alerta no encontrada' });
      return reply.send({ alert: mapGenericAlert(a) });
    }
    return reply.code(400).send({ error: 'Identificador de alerta no válido' });
  });

  // Resolver una alerta con notas. body: { notes?, status? }.
  app.put('/api/v1/admin/fraud/alerts/:aid/resolve', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const b = request.body ?? {};
    const notes = b.notes ?? null;
    const [source, id] = String(request.params.aid).split(':');
    const nowIso = new Date().toISOString();
    if (source === 'referral') {
      // Conserva las notas dentro de detail (la tabla no tiene columna de notas).
      const { data: a } = await supabase.from('referral_fraud_alerts')
        .select('detail').eq('id', id).maybeSingle();
      if (!a) return reply.code(404).send({ error: 'Alerta no encontrada' });
      const detail = { ...(a.detail ?? {}), resolution_notes: notes };
      await supabase.from('referral_fraud_alerts')
        .update({ status: 'resolved', resolved_at: nowIso, detail }).eq('id', id);
    } else if (source === 'fraud') {
      const status = ['investigating', 'resolved'].includes(b.status) ? b.status : 'resolved';
      await supabase.from('fraud_alerts').update({
        status, resolution_notes: notes,
        resolved_by: g.caller.id, resolved_at: status === 'resolved' ? nowIso : null,
      }).eq('id', id);
    } else {
      return reply.code(400).send({ error: 'Identificador de alerta no válido' });
    }
    await logAdminAction(request, g.caller.id, 'fraud_alert_resolve', 'fraud_alert', request.params.aid,
      { notes });
    return reply.send({ ok: true });
  });
}
