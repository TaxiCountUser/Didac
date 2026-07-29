// ============================================================
// TaxiCount - Incidencias + notificaciones push (FCM). Fase B del troceig.
// Plugin de rutas en 2 partes: (1) panel admin de incidencias de todas las
// empresas (lista, mensajes, estado, borrado); (2) endpoints que la app llama
// para enviar push de una incidencia/mensaje y del chat de flota (jefe<->conductor)
// + fleet/boss-name. Sin cambio de comportamiento.
//
// NOTA: los helpers CORE de push (notifyUsers/notifyUser/notifyUsersRaw) se quedan
// en server.js porque los comparten mantenimiento, alertLimit, etc.; aquí se
// inyectan. markService viene de monitoring.js (marca svc_push).
// ============================================================

export function registerIncidentsRoutes(app, {
  supabase, adminGuard, getCaller, logAdminAction,
  notifyUsers, notifyUser, markService, platformAdminIds,
}) {
  // Todas las incidencias de todas las empresas (con nombre de empresa y autor).
  app.get('/api/v1/admin/incidents', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });

    const status = request.query?.status; // 'abierta' | 'resuelta' | undefined
    // Solo tickets de SOPORTE (kind='app'). Los chats de flota (jefe<->conductor)
    // son privados de la empresa y el admin de plataforma NO los ve.
    let q = supabase
      .from('incidents')
      .select('id, kind, body, status, created_at, tenant_id, user_id, hidden_for_tenant, tenants(name), users(email)')
      .eq('kind', 'app')
      .order('created_at', { ascending: false })
      .limit(500);
    if (status === 'abierta' || status === 'resuelta') q = q.eq('status', status);
    const { data, error } = await q;
    if (error) return reply.code(500).send({ error: error.message });
    return reply.send({ incidents: data || [] });
  });

  // Chat de una incidencia (admin <-> cliente). Vía service_role para poder
  // acceder a cualquier empresa.
  app.get('/api/v1/admin/incidents/:id/messages', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { data, error } = await supabase
      .from('incident_messages')
      .select('id, body, user_id, created_at, users(email, name, role, is_admin)')
      .eq('incident_id', request.params.id)
      .order('created_at', { ascending: true });
    if (error) return reply.code(500).send({ error: error.message });
    return reply.send({ messages: data || [] });
  });

  app.post('/api/v1/admin/incidents/:id/messages', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const body = (request.body ?? {}).body;
    if (!body || !String(body).trim()) return reply.code(400).send({ error: 'Mensaje vacío' });
    // Recuperamos el tenant de la incidencia para guardar el mensaje.
    const { data: inc } = await supabase
      .from('incidents').select('tenant_id, status, user_id').eq('id', request.params.id).single();
    if (!inc) return reply.code(404).send({ error: 'Incidencia no encontrada' });
    const { error } = await supabase.from('incident_messages').insert({
      incident_id: request.params.id,
      tenant_id: inc.tenant_id,
      user_id: g.caller.id,
      body: String(body).trim(),
    });
    if (error) return reply.code(400).send({ error: error.message });
    // Avisa al autor del ticket (usuario de la empresa) de la respuesta de soporte.
    if (inc.user_id && inc.user_id !== g.caller.id) {
      await notifyUser(inc.user_id, 'support_response', { text: String(body).trim().slice(0, 140) },
        { type: 'support', incidentId: request.params.id });
    }
    return reply.send({ ok: true });
  });

  // Cambiar el estado de una incidencia (resolver / reabrir) en cualquier empresa.
  app.post('/api/v1/admin/incidents/:id/status', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const status = (request.body ?? {}).status;
    if (status !== 'abierta' && status !== 'resuelta') {
      return reply.code(400).send({ error: 'status debe ser abierta o resuelta' });
    }
    const { error } = await supabase
      .from('incidents')
      .update({ status })
      .eq('id', request.params.id);
    if (error) return reply.code(400).send({ error: error.message });
    return reply.send({ ok: true });
  });

  // Borrar un ticket de soporte (y sus mensajes, por cascada). Solo admin.
  app.delete('/api/v1/admin/incidents/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { error } = await supabase.from('incidents').delete().eq('id', request.params.id);
    if (error) return reply.code(400).send({ error: error.message });
    await logAdminAction(request, g.caller.id, 'incident_delete', 'incident', request.params.id, null);
    return reply.send({ ok: true });
  });

  // --- Notificación push de una incidencia / mensaje (FCM) ---
  // La app lo llama tras crear una incidencia o un mensaje de chat. Si push no
  // está configurado (sin FCM_SERVICE_ACCOUNT), responde ok sin hacer nada.
  app.post('/api/v1/notify-incident', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (!pushEnabled()) return reply.send({ ok: true, push: false });

    const { incidentId, kind, body } = request.body ?? {};
    if (!incidentId) return reply.code(400).send({ error: 'incidentId es obligatorio' });

    const { data: inc } = await supabase
      .from('incidents')
      .select('id, tenant_id, user_id, body, kind')
      .eq('id', incidentId)
      .single();
    if (!inc || inc.tenant_id !== caller.tenant_id) {
      return reply.code(404).send({ error: 'Incidencia no encontrada' });
    }

    // Destinatarios:
    //  - ticket de SOPORTE (kind='app'): avisar a los ADMINS de plataforma.
    //  - incidencia interna: si escribe el conductor -> owners; si el owner -> autor.
    // Nunca te notificas a ti mismo.
    let recipientIds;
    if (inc.kind === 'app') {
      recipientIds = await platformAdminIds();
    } else if (caller.role === 'owner') {
      recipientIds = [inc.user_id];
    } else {
      const { data: owners } = await supabase
        .from('users')
        .select('id')
        .eq('tenant_id', inc.tenant_id)
        .eq('role', 'owner');
      recipientIds = (owners || []).map((o) => o.id);
    }
    recipientIds = recipientIds.filter((id) => id && id !== caller.id);
    if (recipientIds.length === 0) return reply.send({ ok: true, push: true, sent: 0 });

    const { data: toks } = await supabase
      .from('device_tokens')
      .select('token')
      .in('user_id', recipientIds);
    const tokens = (toks || []).map((t) => t.token);

    const support = inc.kind === 'app';
    const title = support
      ? (kind === 'new_message' ? 'Nuevo mensaje de soporte' : 'Nuevo ticket de soporte')
      : (kind === 'new_message' ? 'Nuevo mensaje de incidencia' : 'Nueva incidencia');
    const text = (body || inc.body || '').toString().slice(0, 140);
    const result = await sendToTokens(
      tokens,
      { title, body: text, data: { type: support ? 'support' : 'incident', incidentId: inc.id } },
      request.log,
    );
    if (result.attempted) markService('push', result.ok);

    if (result.invalidTokens.length > 0) {
      await supabase.from('device_tokens').delete().in('token', result.invalidTokens);
    }
    return reply.send({ ok: true, push: true, sent: result.sent });
  });

  // --- Notificación push de un mensaje del chat de flota (jefe <-> conductor) ---
  // La app lo llama tras insertar el mensaje (por RLS) para avisar a la otra
  // parte. El admin de plataforma NO participa en este canal.
  app.post('/api/v1/notify-fleet-message', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (!pushEnabled()) return reply.send({ ok: true, push: false });

    const b = request.body ?? {};
    const driverId = String(b.driver_id ?? '');
    const text = String(b.body ?? '').slice(0, 140);
    if (!driverId) return reply.code(400).send({ error: 'driver_id es obligatorio' });

    // Nombre del remitente (para el título del aviso).
    const { data: me } = await supabase.from('users')
      .select('name, display_name, email').eq('id', caller.id).maybeSingle();
    const senderName = me?.display_name || me?.name || me?.email || '';

    let recipientIds;
    let chatKey;
    if (caller.role === 'owner') {
      // Jefe -> ese conductor. Muestra el NOMBRE del jefe, no "tu jefe".
      recipientIds = [driverId];
      chatKey = senderName ? 'chat_from' : 'chat_from_boss';
    } else {
      // Conductor -> jefe(s) de su tenant.
      const { data: owners } = await supabase.from('users')
        .select('id').eq('tenant_id', caller.tenant_id).eq('role', 'owner');
      recipientIds = (owners || []).map((o) => o.id);
      chatKey = senderName ? 'chat_from' : 'chat_from_driver';
    }
    recipientIds = (recipientIds || []).filter((id) => id && id !== caller.id);
    // El cuerpo es el texto tal cual escrito (no se traduce); el título sí. driverName
    // solo es útil cuando escribe el conductor (para que el jefe abra el chat con su
    // nombre); el conductor que recibe lo ignora.
    await notifyUsers(recipientIds, chatKey, { name: senderName, text },
      { type: 'fleet', driverId, driverName: caller.role === 'owner' ? '' : senderName });
    return reply.send({ ok: true, push: true });
  });

  // Nombre del jefe (owner) del tenant del que pregunta. Para que el conductor
  // vea el NOMBRE real del jefe en el chat (no puede leer la fila del owner por
  // RLS). Vía service_role. Cualquier miembro autenticado del tenant.
  app.get('/api/v1/fleet/boss-name', async (request, reply) => {
    if (!supabase) return reply.code(500).send({ error: 'Supabase no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (!caller.tenant_id) return reply.send({ name: '' });
    const { data: owner } = await supabase.from('users')
      .select('name, display_name, email').eq('tenant_id', caller.tenant_id)
      .eq('role', 'owner').order('created_at', { ascending: true }).limit(1).maybeSingle();
    const name = owner?.display_name || owner?.name || owner?.email || '';
    return reply.send({ name });
  });
}
