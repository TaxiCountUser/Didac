// ============================================================
// TaxiCount - Visores de auditoría (admin, solo lectura). Fase B del troceig.
// Plugin de rutas: 3 lectores del panel de Auditoría — log de acciones admin
// (admin_actions_log), eventos de seguridad (security_events, capa B) y errores
// de la app cliente (client_errors, agregados por mensaje). Solo admin, sin
// escritura. Deps del closure inyectadas por parámetro.
// ============================================================

export function registerAuditViewerRoutes(app, { supabase, adminGuard }) {
  // Logs de auditoría de acciones administrativas. Filtros: ?action_type= &admin_id=.
  app.get('/api/v1/admin/audit/logs', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const qp = request.query ?? {};
    const limit = Math.min(Math.max(parseInt(qp.limit ?? '50', 10) || 50, 1), 200);
    const offset = Math.max(parseInt(qp.offset ?? '0', 10) || 0, 0);
    let q = supabase.from('admin_actions_log')
      .select('id, admin_id, action_type, target_type, target_id, details, ip_address, created_at, '
        + 'admin:admin_id(email, name)', { count: 'exact' })
      .order('created_at', { ascending: false });
    if (qp.action_type) q = q.eq('action_type', qp.action_type);
    if (qp.admin_id) q = q.eq('admin_id', qp.admin_id);
    if (qp.from) q = q.gte('created_at', qp.from);
    if (qp.to) q = q.lte('created_at', qp.to);
    const { data, count, error } = await q.range(offset, offset + limit - 1);
    if (error) return reply.code(500).send({ error: error.message });
    return reply.send({ logs: data ?? [], total: count ?? (data ?? []).length, limit, offset });
  });

  // Logs de SEGURIDAD (capa B) para la pestaña "Logs" de Auditoría. Filtros:
  // ?event_type= &from= &to= + paginación. Solo admin.
  app.get('/api/v1/admin/security/events', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const qp = request.query ?? {};
    const limit = Math.min(Math.max(parseInt(qp.limit ?? '50', 10) || 50, 1), 200);
    const offset = Math.max(parseInt(qp.offset ?? '0', 10) || 0, 0);
    let q = supabase.from('security_events')
      .select('id, event_type, actor_id, tenant_id, ip_address, user_agent, method, path, '
        + 'status_code, trace_id, details, created_at, actor:actor_id(email, name)', { count: 'exact' })
      .order('created_at', { ascending: false });
    if (qp.event_type) q = q.eq('event_type', String(qp.event_type));
    if (qp.from) q = q.gte('created_at', qp.from);
    if (qp.to) q = q.lte('created_at', qp.to);
    const { data, count, error } = await q.range(offset, offset + limit - 1);
    if (error) return reply.code(500).send({ error: error.message });
    // Resumen de posture 24h (KPI de Auditoría → Logs): recuento por tipo.
    let summary = null;
    try {
      const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
      const cnt = async (type) => {
        const { count: c } = await supabase.from('security_events')
          .select('id', { count: 'exact', head: true })
          .eq('event_type', type).gte('created_at', since);
        return c ?? 0;
      };
      const [esc, rl, tok, login] = await Promise.all([
        cnt('privilege_escalation'), cnt('rate_limit'), cnt('invalid_token'), cnt('login_failed'),
      ]);
      summary = { privilege_escalation: esc, rate_limit: rl, invalid_token: tok, login_failed: login };
    } catch { /* best-effort */ }
    return reply.send({
      events: data ?? [], total: count ?? (data ?? []).length, limit, offset, summary,
    });
  });

  // Errores del CLIENTE AGREGADOS (mig. 082) para Auditoría → "Errors tècnics".
  // Agrupa por mensaje: recuento + última vez + pantalla ejemplo (últimos 30 días),
  // así los recurrentes suben arriba. Solo admin.
  app.get('/api/v1/admin/client-errors', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const since = new Date(Date.now() - 30 * 86400000).toISOString();
    const { data, error } = await supabase.from('client_errors')
      .select('message, screen, created_at')
      .gte('created_at', since)
      .order('created_at', { ascending: false })
      .limit(5000);
    if (error) return reply.code(500).send({ error: error.message });
    const byMsg = {};
    for (const r of data ?? []) {
      const m = (byMsg[r.message] ||= { message: r.message, count: 0, last_at: r.created_at, screen: r.screen });
      m.count++;
      if (r.created_at > m.last_at) { m.last_at = r.created_at; m.screen = r.screen; }
    }
    const errors = Object.values(byMsg).sort((a, b) => b.count - a.count).slice(0, 100);
    return reply.send({ errors, total: (data ?? []).length });
  });
}
