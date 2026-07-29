// ============================================================
// TaxiCount - Gestión de empresas (admin). Fase B del troceig.
// Plugin de rutas: ficha de empresa (tenant+usuarios+recuentos+ingresos), buscador
// global, vehículos, editar/cerrar/borrar/purgar/reactivar empresa, reset de cupón
// de bienvenida y desglose de facturas (Stripe en vivo). Solo admin.
//
// closeTenantAccount vive AQUÍ (solo lo usan cierre/borrado, que están en este
// módulo). Se inyecta readTenantRevenue (helper financiero que se queda en server.js
// y se moverá con el módulo financiero). NOTA: /admin/billing (dashboard financiero)
// y test-rewards (utilidad de pruebas) se quedan en server.js a propósito.
// ============================================================

export function registerCompaniesRoutes(app, {
  supabase, stripe, log, adminGuard, getCaller, logAdminAction,
  readTenantRevenue,
}) {
  // Detalle completo de una empresa: tenant + usuarios + recuentos.
  app.get('/api/v1/admin/company/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const id = request.params.id;

    const { data: tenant, error } = await supabase
      .from('tenants')
      .select('id, name, solo, subscription_status, plan_id, drivers_limit, trial_ends_at, created_at, closed_at, stripe_customer_id, stripe_subscription_id, join_code')
      .eq('id', id)
      .single();
    if (error || !tenant) return reply.code(404).send({ error: 'Empresa no encontrada' });

    const { data: users } = await supabase
      .from('users')
      .select('id, email, name, display_name, username, role, active, is_admin, created_at, annual_price_paid')
      .eq('tenant_id', id)
      .order('role', { ascending: true });

    // Recuentos (head:true devuelve solo el count, sin filas).
    const countOf = async (table) => {
      const { count } = await supabase
        .from(table)
        .select('id', { count: 'exact', head: true })
        .eq('tenant_id', id);
      return count || 0;
    };
    const [vehicles, transactions, incidents] = await Promise.all([
      countOf('vehicles'),
      countOf('transactions'),
      countOf('incidents'),
    ]);

    // PROTECCIÓN DE DATOS: el admin de plataforma NO ve el dinero de las empresas
    // ni el contenido de las carreras (importes, ingresos/gastos, cliente,
    // origen/destino, descripción). Solo damos recuentos, nunca las cifras ni el
    // detalle. Así TaxiCount no accede al contenido económico/de cliente.
    const summary = null; // enmascarado (*****)

    // Vehículos de la empresa.
    const { data: vehicleList } = await supabase
      .from('vehicles')
      .select('id, license_plate, model')
      .eq('tenant_id', id)
      .order('created_at', { ascending: true });

    // Tickets de SOPORTE de la empresa (kind='app'). El chat de flota
    // (jefe<->conductor) vive en fleet_messages y el admin no lo ve; aquí solo
    // salen las incidencias de soporte, igual que en la bandeja global.
    const { data: incidentList } = await supabase
      .from('incidents')
      .select('id, kind, body, status, created_at, users(email)')
      .eq('tenant_id', id)
      .eq('kind', 'app')
      .order('created_at', { ascending: false })
      .limit(100);

    // Datos de SUSCRIPCIÓN (lado TaxiCount, no finanzas del cliente): asientos
    // ocupados y días gratis conseguidos (retos + referidos). Para la ficha.
    const activeDrivers = (users || []).filter((u) => u.role === 'driver' && u.active !== false);
    const freeDays = await freeDaysForTenant(id);
    // Ingresos REALES cobrados a esta empresa (Stripe): total pagado + lo
    // descontado con cupones. Esto NO son las finanzas internas del cliente
    // (sus carreras), sino lo que ELLA nos ha pagado a nosotros. En euros.
    const rev = await readTenantRevenue(tenant.stripe_customer_id);

    return reply.send({
      tenant,
      users: users || [],
      counts: { vehicles, transactions, incidents },
      summary,                       // null: oculto por protección de datos
      recent_transactions: [],       // oculto por protección de datos
      financials_masked: true,       // el front muestra ***** en vez de cifras
      vehicles_list: vehicleList || [],
      incidents_list: incidentList || [],
      billing: {
        // Neto real: pagado menos devuelto (reembolsos).
        paid_total: Number(((rev.paid - (rev.refunded || 0)) / 100).toFixed(2)),
        coupon_total: Number((rev.discount / 100).toFixed(2)),
        refund_total: Number(((rev.refunded || 0) / 100).toFixed(2)),
        paid_invoices: rev.count,
        free_days: freeDays.total,
        free_days_challenges: freeDays.challenges,
        free_days_referrals: freeDays.referrals,
        // Crédito de recompensas (reto + referido) aplicado en Stripe, en euros.
        reward_credit_eur: Number((freeDays.total_cents / 100).toFixed(2)),
        reward_credit_challenges_eur: Number((freeDays.challenges_cents / 100).toFixed(2)),
        reward_credit_referrals_eur: Number((freeDays.referrals_cents / 100).toFixed(2)),
        active_drivers: activeDrivers.length,
      },
    });
  });

  // Buscador global del admin: empresa por nombre, usuario por email/nombre/
  // usuario, o vehículo por matrícula. Devuelve empresas con el motivo del
  // match, para saltar directamente a su ficha.
  app.get('/api/v1/admin/search', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const q = String(request.query?.q ?? '').trim();
    if (q.length < 2) return reply.send({ results: [] });
    const like = `%${q}%`;

    const [byTenant, byUser, byPlate] = await Promise.all([
      supabase.from('tenants').select('id, name').ilike('name', like).limit(10),
      supabase.from('users')
        .select('tenant_id, email, name, username, tenants:tenant_id(id, name)')
        .or(`email.ilike.${like},name.ilike.${like},username.ilike.${like}`)
        .not('tenant_id', 'is', null).limit(10),
      supabase.from('vehicles')
        .select('tenant_id, license_plate, tenants:tenant_id(id, name)')
        .ilike('license_plate', like).limit(10),
    ]);

    const results = [];
    const seen = new Set();
    const push = (id, name, reason) => {
      if (!id || seen.has(`${id}|${reason}`)) return;
      seen.add(`${id}|${reason}`);
      results.push({ tenant_id: id, tenant_name: name ?? '—', reason });
    };
    for (const t of byTenant.data ?? []) push(t.id, t.name, '');
    for (const u of byUser.data ?? []) {
      push(u.tenants?.id ?? u.tenant_id, u.tenants?.name,
        u.email ?? u.username ?? u.name ?? '');
    }
    for (const v of byPlate.data ?? []) {
      push(v.tenants?.id ?? v.tenant_id, v.tenants?.name, v.license_plate ?? '');
    }
    return reply.send({ results: results.slice(0, 15) });
  });

  // Añadir un vehículo a una empresa (admin).
  app.post('/api/v1/admin/company/:id/vehicle', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { license_plate, model } = request.body ?? {};
    if (!license_plate || !String(license_plate).trim()) {
      return reply.code(400).send({ error: 'La matrícula es obligatoria' });
    }
    const { error } = await supabase.from('vehicles').insert({
      tenant_id: request.params.id,
      license_plate: String(license_plate).trim(),
      model: model ? String(model).trim() : null,
    });
    if (error) return reply.code(400).send({ error: error.message });
    await logAdminAction(request, g.caller.id, 'vehicle_add', 'tenant', request.params.id,
      { license_plate: String(license_plate).trim() });
    return reply.send({ ok: true });
  });

  // Editar un vehículo (admin).
  app.patch('/api/v1/admin/vehicle/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const b = request.body ?? {};
    const patch = {};
    if (b.license_plate !== undefined) patch.license_plate = String(b.license_plate).trim();
    if (b.model !== undefined) patch.model = b.model ? String(b.model).trim() : null;
    if (Object.keys(patch).length === 0) return reply.code(400).send({ error: 'Nada que actualizar' });
    const { error } = await supabase.from('vehicles').update(patch).eq('id', request.params.id);
    if (error) return reply.code(400).send({ error: error.message });
    await logAdminAction(request, g.caller.id, 'vehicle_update', 'vehicle', request.params.id, patch);
    return reply.send({ ok: true });
  });

  // Eliminar un vehículo (admin).
  app.delete('/api/v1/admin/vehicle/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { error } = await supabase.from('vehicles').delete().eq('id', request.params.id);
    if (error) return reply.code(400).send({ error: error.message });
    await logAdminAction(request, g.caller.id, 'vehicle_delete', 'vehicle', request.params.id, null);
    return reply.send({ ok: true });
  });

  // Modificar una empresa (suscripción, plan, límite, prueba, nombre, solo).
  app.patch('/api/v1/admin/company/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const b = request.body ?? {};
    const patch = {};
    if (b.name !== undefined) patch.name = String(b.name).trim();
    if (b.subscription_status !== undefined) patch.subscription_status = b.subscription_status;
    if (b.plan_id !== undefined) patch.plan_id = b.plan_id === '' ? null : b.plan_id;
    if (b.drivers_limit !== undefined) {
      patch.drivers_limit = (b.drivers_limit === null || b.drivers_limit === '')
        ? null : Number(b.drivers_limit);
    }
    if (b.solo !== undefined) patch.solo = b.solo === true || b.solo === 'true';
    if (b.join_code !== undefined) {
      const code = String(b.join_code).trim().toUpperCase();
      patch.join_code = code === '' ? null : code;
    }
    if (b.trial_ends_at !== undefined) patch.trial_ends_at = b.trial_ends_at; // ISO o null
    // Atajo: SUMAR (o restar, con negativo) N días a la prueba. Base = el fin de
    // prueba actual si aún es futuro; si ya pasó, ahora. Así +N amplía y -N quita
    // días (si se resta más de lo que queda, la prueba queda caducada).
    if (b.extend_trial_days !== undefined && b.extend_trial_days !== null) {
      const days = Number(b.extend_trial_days);
      if (!Number.isNaN(days) && days !== 0) {
        const { data: cur } = await supabase.from('tenants')
          .select('trial_ends_at').eq('id', request.params.id).maybeSingle();
        const curEnd = cur?.trial_ends_at ? new Date(cur.trial_ends_at).getTime() : 0;
        const base = Math.max(Date.now(), curEnd);
        patch.trial_ends_at = new Date(base + days * 86400000).toISOString();
      }
    }
    if (Object.keys(patch).length === 0) {
      return reply.code(400).send({ error: 'Nada que actualizar' });
    }
    const { error } = await supabase.from('tenants').update(patch).eq('id', request.params.id);
    if (error) {
      const dup = /duplicate|unique|23505/i.test(error.message || '');
      return reply.code(dup ? 409 : 400)
        .send({ error: dup ? 'Ese código de flota ya está en uso' : error.message });
    }
    await logAdminAction(request, g.caller.id, 'company_update', 'tenant', request.params.id, patch);
    return reply.send({ ok: true });
  });

  // CIERRE LÓGICO de una empresa con retención fiscal (5 años): NO borra la
  // empresa (eso borraría en cascada sus carreras). Marca closed_at, anonimiza,
  // cancela la suscripción en Stripe (si cancelStripe) y elimina las cuentas de
  // acceso; las carreras quedan (user_id -> null) y se purgan a los 5 años
  // (purge_expired_retention). Lo usan el cierre del admin y la baja del propio
  // owner. Un admin de plataforma NUNCA pierde su cuenta: solo se le desvincula.
  async function closeTenantAccount(id, { cancelStripe } = {}) {
    if (cancelStripe && stripe) {
      const { data: t } = await supabase.from('tenants')
        .select('stripe_subscription_id').eq('id', id).maybeSingle();
      if (t?.stripe_subscription_id) {
        try { await stripe.subscriptions.cancel(t.stripe_subscription_id); }
        catch (e) { log.warn(`[close] cancel stripe ${id}: ${e.message}`); }
      }
    }
    const { data: users } = await supabase.from('users').select('id, is_admin').eq('tenant_id', id);
    const { error } = await supabase.from('tenants').update({
      closed_at: new Date().toISOString(),
      name: 'Empresa dada de baja',
      subscription_status: 'canceled',
      stripe_customer_id: null,
      stripe_subscription_id: null,
      join_code: null,
    }).eq('id', id);
    if (error) throw new Error(error.message);
    let removed = 0;
    for (const u of users || []) {
      if (u.is_admin) {
        await supabase.from('users').update({ tenant_id: null }).eq('id', u.id);
        continue;
      }
      try { await supabase.auth.admin.deleteUser(u.id); } catch (_) {}
      removed += 1;
    }
    return { removed };
  }

  // Eliminar una empresa entera (admin): cierre lógico + eliminación de accesos.
  app.delete('/api/v1/admin/company/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const id = request.params.id;
    let removed = 0;
    try { ({ removed } = await closeTenantAccount(id, { cancelStripe: false })); }
    catch (e) { return reply.code(400).send({ error: e.message }); }
    await logAdminAction(request, g.caller.id, 'company_close', 'tenant', id,
      { removed_access: removed });
    return reply.send({ ok: true, closed: true, removed_access: removed });
  });

  // Baja de la propia empresa (el OWNER cierra su cuenta). Cancela la suscripción
  // en Stripe, marca la empresa como dada de baja (retención GDPR 5 años) y
  // elimina los accesos (incluido el suyo). Exige confirmar escribiendo el nombre
  // de la empresa para evitar accidentes. Irreversible desde la app.
  app.post('/api/v1/company/close', async (request, reply) => {
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (caller.role !== 'owner') return reply.code(403).send({ error: 'Solo el propietario puede dar de baja la empresa' });
    const { data: t } = await supabase.from('tenants')
      .select('id, name, closed_at').eq('id', caller.tenant_id).maybeSingle();
    if (!t) return reply.code(404).send({ error: 'Empresa no encontrada' });
    if (t.closed_at) return reply.code(400).send({ error: 'La empresa ya está dada de baja' });
    const confirmName = String((request.body ?? {}).confirm_name ?? '').trim();
    if (confirmName.toLowerCase() !== String(t.name || '').trim().toLowerCase()) {
      return reply.code(400).send({ code: 'name_mismatch', error: 'El nombre de la empresa no coincide' });
    }
    try {
      const { removed } = await closeTenantAccount(caller.tenant_id, { cancelStripe: true });
      return reply.send({ ok: true, removed_access: removed });
    } catch (e) {
      return reply.code(500).send({ error: e.message });
    }
  });

  // Purga DEFINITIVA de UNA empresa YA dada de baja: borra el tenant y, en
  // cascada, todos sus datos (carreras, vehículos, retos, lecturas…). Irreversible.
  // Guarda contra borrar una empresa activa: exige closed_at (dada de baja).
  // Pensado para limpiar empresas de prueba sin esperar la retención de 5 años.
  app.delete('/api/v1/admin/company/:id/purge', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const id = request.params.id;
    const { data: t } = await supabase.from('tenants')
      .select('id, name, closed_at').eq('id', id).maybeSingle();
    if (!t) return reply.code(404).send({ error: 'Empresa no encontrada' });
    if (!t.closed_at) {
      return reply.code(400).send({ error: 'Solo se pueden purgar empresas dadas de baja' });
    }
    // Desvincula (por si acaso) cualquier admin de plataforma que siga apuntando
    // a este tenant, para no borrar su cuenta con la cascada.
    await supabase.from('users').update({ tenant_id: null }).eq('tenant_id', id).eq('is_admin', true);
    const { error } = await supabase.from('tenants').delete().eq('id', id);
    if (error) return reply.code(400).send({ error: error.message });
    await logAdminAction(request, g.caller.id, 'company_purge', 'tenant', id, { name: t.name });
    return reply.send({ ok: true, purged: true });
  });

  // REACTIVAR una empresa dada de baja (antes de purgarla): la baja eliminó las
  // cuentas de acceso pero conservó los datos (retención). Esto deshace el cierre
  // lógico (closed_at), restaura el nombre (la baja lo anonimizó), regenera el
  // código de flota, da un periodo de prueba para que pueda re-suscribirse y CREA
  // la cuenta del owner con contraseña temporal (el trigger de alta la vincula al
  // tenant existente vía metadata). Los datos históricos (carreras, vehículos…)
  // reaparecen; los conductores deben re-invitarse (sus cuentas se eliminaron).
  // Reinicia el cupón de bienvenida de una empresa: borra coupon_redeemed_code,
  // así vuelve a verse el aviso del cupón activo (útil para pruebas y soporte;
  // un refund de Stripe NO toca esta columna de la app). Auditado.
  app.post('/api/v1/admin/company/:id/reset-welcome-coupon', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const id = request.params.id;
    const { error } = await supabase.from('tenants')
      .update({ coupon_redeemed_code: null }).eq('id', id);
    if (error) return reply.code(500).send({ error: error.message });
    await logAdminAction(request, g.caller?.id ?? null, 'reset_welcome_coupon', 'tenant', id, null);
    return reply.send({ ok: true });
  });

  // Desglose del "Total pagado" de una empresa: lista sus facturas de Stripe (fecha,
  // concepto, importe, estado) leídas EN VIVO, para que el acumulado deje de ser opaco.
  app.get('/api/v1/admin/company/:id/invoices', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { data: t } = await supabase.from('tenants')
      .select('stripe_customer_id').eq('id', request.params.id).maybeSingle();
    const cust = t?.stripe_customer_id;
    if (!stripe || !cust) return reply.send({ invoices: [] });
    try {
      const out = [];
      for await (const inv of stripe.invoices.list({ customer: cust, limit: 100 })) {
        const line = inv.lines?.data?.[0];
        const nLines = inv.lines?.data?.length ?? 0;
        out.push({
          date: (inv.status_transitions?.paid_at ?? inv.created ?? 0),
          number: inv.number ?? inv.id,
          amount_paid: Number(((inv.amount_paid ?? 0) / 100).toFixed(2)),
          discount: Number((((inv.total_discount_amounts ?? []).reduce((s, d) => s + (d.amount || 0), 0)) / 100).toFixed(2)),
          status: inv.status,               // paid | open | void | draft | uncollectible
          reason: inv.billing_reason,       // subscription_create | subscription_cycle | subscription_update | manual
          description: line?.description ?? (nLines > 1 ? `${nLines} líneas` : ''),
        });
      }
      return reply.send({ invoices: out });
    } catch (e) {
      request.log.error(e);
      return reply.code(502).send({ error: 'No se pudieron leer las facturas' });
    }
  });

  app.post('/api/v1/admin/company/:id/reactivate', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const id = request.params.id;
    const b = request.body ?? {};
    const ownerEmail = String(b.owner_email ?? '').trim().toLowerCase();
    const companyName = String(b.company_name ?? '').trim();
    const trialDays = Math.min(60, Math.max(1, Math.trunc(Number(b.trial_days)) || 15));
    if (!ownerEmail || !ownerEmail.includes('@')) {
      return reply.code(400).send({ error: 'Correo del propietario inválido' });
    }
    if (!companyName) return reply.code(400).send({ error: 'El nombre de la empresa es obligatorio' });

    const { data: t } = await supabase.from('tenants')
      .select('id, name, closed_at').eq('id', id).maybeSingle();
    if (!t) return reply.code(404).send({ error: 'Empresa no encontrada' });
    if (!t.closed_at) return reply.code(400).send({ error: 'La empresa no está dada de baja' });

    // El correo no puede pertenecer ya a otra cuenta (misma pre-comprobación que
    // al invitar conductores: sin esto el trigger falla con un error confuso).
    const { data: dup } = await supabase.from('users')
      .select('id').ilike('email', ownerEmail).maybeSingle();
    if (dup) return reply.code(409).send({ error: 'Ese correo ya está registrado en TaxiCount; usa otro.' });

    // 1) Reabrir el tenant: quitar closed_at, restaurar nombre, nueva prueba y
    //    código de flota nuevo (con reintentos por si colisiona el unique).
    let joinCode = null;
    for (let i = 0; i < 5 && !joinCode; i++) {
      const code = randomBytes(4).toString('hex').slice(0, 6).toUpperCase();
      const { error } = await supabase.from('tenants').update({
        closed_at: null,
        name: companyName,
        subscription_status: 'trialing',
        trial_ends_at: new Date(Date.now() + trialDays * 86400000).toISOString(),
        join_code: code,
      }).eq('id', id);
      if (!error) joinCode = code;
      else if (!/duplicate|unique|23505/i.test(error.message || '')) {
        return reply.code(400).send({ error: error.message });
      }
    }
    if (!joinCode) return reply.code(500).send({ error: 'No se pudo generar el código de flota' });

    // 2) Crear la cuenta del owner vinculada al tenant (metadata -> trigger).
    const tempPassword = generateTempPassword();
    const { data: created, error: createErr } = await supabase.auth.admin.createUser({
      email: ownerEmail,
      password: tempPassword,
      email_confirm: true,
      user_metadata: { role: 'owner', tenant_id: id, name: b.owner_name ?? null },
    });
    if (createErr) {
      // Deshacer la reapertura para no dejar una empresa abierta sin owner.
      await supabase.from('tenants').update({
        closed_at: t.closed_at, name: t.name, join_code: null, trial_ends_at: null,
        subscription_status: 'canceled',
      }).eq('id', id);
      return reply.code(400).send({ error: createErr.message || 'No se pudo crear la cuenta del owner' });
    }
    await supabase.from('users').update({ must_change_password: true }).eq('id', created.user.id);

    await logAdminAction(request, g.caller.id, 'company_reactivate', 'tenant', id,
      { owner_email: ownerEmail, trial_days: trialDays });
    log.info(`[reactivate] tenant ${id} reabierto; owner ${ownerEmail}`);
    return reply.send({ ok: true, owner_email: ownerEmail, tempPassword, join_code: joinCode, trial_days: trialDays });
  });
}
