// ============================================================
// TaxiCount - Gestión de administradores y usuarios (admin). Fase B del troceig.
// Plugin de rutas en 2 partes: (1) administradores de la plataforma (listar,
// conceder/revocar is_admin); (2) usuarios de cualquier empresa (modificar rol/
// estado, borrar, ver/asignar vehículos). Solo admin. Sin cambio de comportamiento.
// ============================================================

export function registerAdminUsersRoutes(app, { supabase, adminGuard, logAdminAction }) {
  // Lista de administradores actuales (para gestionarlos).
  app.get('/api/v1/admin/admins', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { data, error } = await supabase
      .from('users')
      .select('id, email, name')
      .eq('is_admin', true)
      .order('email', { ascending: true });
    if (error) return reply.code(500).send({ error: error.message });
    return reply.send({ admins: data || [] });
  });

  // Nombrar (o quitar) admin a otro usuario por su correo.
  app.post('/api/v1/admin/make-admin', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { email, isAdmin } = request.body ?? {};
    if (!email) return reply.code(400).send({ error: 'Falta el correo' });
    const { data, error } = await supabase
      .from('users')
      .update({ is_admin: isAdmin === false ? false : true })
      .eq('email', String(email).trim().toLowerCase())
      .select('id, email, is_admin');
    if (error) return reply.code(400).send({ error: error.message });
    if (!data || data.length === 0) {
      return reply.code(404).send({ error: 'No hay ningún usuario con ese correo' });
    }
    // Conceder/revocar admin es la acción más sensible: queda en auditoría.
    await logAdminAction(request, g.caller.id, isAdmin === false ? 'admin_revoke' : 'admin_grant',
      'user', data[0].id, { email: data[0].email, is_admin: data[0].is_admin });
    return reply.send({ ok: true, user: data[0] });
  });

  // Modificar un usuario de cualquier empresa (activar, rol, nombre, admin).
  app.patch('/api/v1/admin/user/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const b = request.body ?? {};
    const patch = {};
    if (b.active !== undefined) patch.active = b.active === true || b.active === 'true';
    if (b.role !== undefined && (b.role === 'owner' || b.role === 'driver')) patch.role = b.role;
    if (b.name !== undefined) patch.name = String(b.name).trim() || null;
    if (b.is_admin !== undefined) patch.is_admin = b.is_admin === true || b.is_admin === 'true';
    if (Object.keys(patch).length === 0) {
      return reply.code(400).send({ error: 'Nada que actualizar' });
    }
    const { error } = await supabase.from('users').update(patch).eq('id', request.params.id);
    if (error) return reply.code(400).send({ error: error.message });
    await logAdminAction(request, g.caller.id, 'user_update', 'user', request.params.id, patch);
    return reply.send({ ok: true });
  });

  // Eliminar un usuario (su perfil + su cuenta de auth).
  app.delete('/api/v1/admin/user/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const id = request.params.id;
    await supabase.from('users').delete().eq('id', id);
    try {
      await supabase.auth.admin.deleteUser(id);
    } catch (e) {
      if (!/not.*found|404/i.test(e?.message || '')) {
        return reply.code(400).send({ error: `No se pudo eliminar la cuenta: ${e.message}` });
      }
    }
    await logAdminAction(request, g.caller.id, 'user_delete', 'user', id, null);
    return reply.send({ ok: true });
  });

  // Liberar un correo: borra la cuenta asociada a un email (perfil en public.users
  // + cuenta de auth si existe), para poder REUTILIZARLO. Pensado para RESIDUOS de
  // pruebas y huérfanos (fila en users sin auth, o auth sin empresa). Nunca borra
  // administradores de plataforma. Solo admin; queda en auditoría.
  app.post('/api/v1/admin/free-email', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const email = String((request.body ?? {}).email || '').trim().toLowerCase();
    if (!email) return reply.code(400).send({ error: 'Falta el correo' });

    // Perfiles en public.users con ese correo (puede haber huérfanos sin tenant).
    const { data: profiles } = await supabase
      .from('users').select('id, tenant_id, role, is_admin, name').ilike('email', email);
    if ((profiles || []).some((p) => p.is_admin)) {
      return reply.code(409).send({
        error: 'Ese correo es de un administrador de plataforma; no se libera aquí.',
      });
    }

    // Cuenta de auth con ese correo (búsqueda en la lista; base aún pequeña).
    let authId = null;
    try {
      const { data: list } = await supabase.auth.admin.listUsers({ page: 1, perPage: 1000 });
      const au = (list?.users || []).find((u) => (u.email || '').toLowerCase() === email);
      if (au) authId = au.id;
    } catch (e) { request.log.warn(`[free-email] listUsers: ${e.message}`); }

    if ((profiles || []).length === 0 && !authId) {
      return reply.code(404).send({ error: 'No hay ninguna cuenta con ese correo.' });
    }

    // Borra el/los perfil(es) por correo y la cuenta de auth (si la hay).
    await supabase.from('users').delete().ilike('email', email);
    let authDeleted = false;
    if (authId) {
      try { await supabase.auth.admin.deleteUser(authId); authDeleted = true; }
      catch (e) {
        if (!/not.*found|404/i.test(e?.message || '')) {
          request.log.warn(`[free-email] deleteUser: ${e.message}`);
        }
      }
    }
    await logAdminAction(request, g.caller.id, 'free_email', 'user',
      authId || (profiles?.[0]?.id ?? null),
      { email, profilesRemoved: (profiles || []).length, authDeleted });
    return reply.send({ ok: true, email, profilesRemoved: (profiles || []).length, authDeleted });
  });

  // Vehículos asignados a un conductor (admin): lista de vehicle_id.
  app.get('/api/v1/admin/user/:id/vehicles', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { data, error } = await supabase
      .from('driver_vehicles').select('vehicle_id').eq('user_id', request.params.id);
    if (error) return reply.code(500).send({ error: error.message });
    return reply.send({ vehicleIds: (data || []).map((r) => r.vehicle_id) });
  });

  // Asignar qué vehículos usa un conductor (admin). Reemplaza el conjunto.
  app.post('/api/v1/admin/user/:id/vehicles', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const userId = request.params.id;
    const vehicleIds = Array.isArray((request.body ?? {}).vehicleIds) ? request.body.vehicleIds : [];
    // tenant del conductor (para las filas de driver_vehicles).
    const { data: u } = await supabase.from('users').select('tenant_id').eq('id', userId).single();
    if (!u?.tenant_id) return reply.code(404).send({ error: 'Conductor no encontrado' });
    await supabase.from('driver_vehicles').delete().eq('user_id', userId);
    if (vehicleIds.length > 0) {
      const rows = vehicleIds.map((vid) => ({ tenant_id: u.tenant_id, user_id: userId, vehicle_id: vid }));
      const { error } = await supabase.from('driver_vehicles').insert(rows);
      if (error) return reply.code(400).send({ error: error.message });
    }
    return reply.send({ ok: true });
  });
}
