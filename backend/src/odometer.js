// ============================================================
// TaxiCount - Corrección de odómetro (admin). Fase B del troceig.
// Plugin de rutas: corregir/eliminar los km que alimentan los retos y el km/día,
// desde sus dos orígenes (odometer_readings de jornada + transactions.odometer_km
// de cada carrera) + el odómetro inicial del vehículo. Solo admin. Sin cambio de
// comportamiento; deps del closure inyectadas por parámetro.
// ============================================================

export function registerOdometerRoutes(app, { supabase, adminGuard, logAdminAction, getCaller }) {
  registerOdometerSelfRoutes(app, { supabase, logAdminAction, getCaller });
  // Admin: km de un conductor para CORREGIR un valor mal introducido. Devuelve
  // AMBOS orígenes que alimentan los retos y el km/día: (1) lecturas de jornada
  // (odometer_readings) y (2) el odómetro apuntado en cada carrera (transactions
  // .odometer_km). Cada uno se corrige/elimina con su propio endpoint. Se unifican
  // en una lista `entries` (source: 'reading' | 'transaction'), más recientes primero.
  app.get('/api/v1/admin/drivers/:userId/odometer', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const limit = Math.min(Number(request.query?.limit) || 60, 300);
    const [rd, tx] = await Promise.all([
      supabase.from('odometer_readings')
        .select('id, vehicle_id, reading_km, taken_at, vehicles:vehicle_id(license_plate, model)')
        .eq('user_id', request.params.userId)
        .order('taken_at', { ascending: false }).limit(limit),
      supabase.from('transactions')
        .select('id, vehicle_id, odometer_km, created_at, vehicles:vehicle_id(license_plate, model)')
        .eq('user_id', request.params.userId).not('odometer_km', 'is', null)
        .order('created_at', { ascending: false }).limit(limit),
    ]);
    if (rd.error) return reply.code(500).send({ error: rd.error.message });
    // Km INICIAL de cada vehículo que usa el conductor (source 'vehicle'): es el
    // punto de partida del odómetro (al dar de alta el coche). Aparte de las
    // lecturas de jornada y del odómetro de cada carrera.
    const vehIds = [...new Set([
      ...(rd.data ?? []).map((r) => r.vehicle_id),
      ...(tx.data ?? []).map((t) => t.vehicle_id),
    ].filter(Boolean))];
    let vehicles = [];
    if (vehIds.length) {
      const { data: vs } = await supabase.from('vehicles')
        .select('id, license_plate, initial_odometer, created_at').in('id', vehIds);
      vehicles = vs ?? [];
    }
    const entries = [
      ...vehicles.map((v) => ({
        source: 'vehicle', id: v.id, km: v.initial_odometer ?? 0, at: v.created_at,
        plate: v.license_plate ?? null,
      })),
      ...(rd.data ?? []).map((r) => ({
        source: 'reading', id: r.id, km: r.reading_km, at: r.taken_at,
        plate: (r.vehicles || {}).license_plate ?? null,
      })),
      ...(tx.data ?? []).map((t) => ({
        source: 'transaction', id: t.id, km: t.odometer_km, at: t.created_at,
        plate: (t.vehicles || {}).license_plate ?? null,
      })),
    ].sort((a, b) => new Date(b.at) - new Date(a.at));
    // `readings` se mantiene por compatibilidad con clientes antiguos.
    return reply.send({ entries, readings: rd.data ?? [] });
  });

  // Admin: corrige el km de una lectura (reading_km). Queda auditado con el valor
  // anterior y el nuevo. Los retos se recalculan solos en la próxima lectura (leen
  // el odómetro en vivo); no hay rollups de km que refrescar.
  app.patch('/api/v1/admin/odometer/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const km = Number((request.body ?? {}).reading_km);
    if (!Number.isFinite(km) || km < 0 || km > 100000000) {
      return reply.code(400).send({ error: 'km no válido' });
    }
    const { data: row } = await supabase.from('odometer_readings')
      .select('id, tenant_id, user_id, reading_km').eq('id', request.params.id).maybeSingle();
    if (!row) return reply.code(404).send({ error: 'Lectura no encontrada' });
    const newKm = Math.round(km);
    await supabase.from('odometer_readings')
      .update({ reading_km: newKm }).eq('id', row.id);
    await logAdminAction(request, g.caller?.id ?? null, 'odometer_correct', 'odometer_readings', row.id,
      { user_id: row.user_id, from: row.reading_km, to: newKm });
    return reply.send({ ok: true, reading_km: newKm });
  });

  // Admin: elimina una lectura errónea (p. ej. un km de inicio duplicado o falso).
  app.delete('/api/v1/admin/odometer/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { data: row } = await supabase.from('odometer_readings')
      .select('id, user_id, reading_km, taken_at').eq('id', request.params.id).maybeSingle();
    if (!row) return reply.code(404).send({ error: 'Lectura no encontrada' });
    await supabase.from('odometer_readings').delete().eq('id', row.id);
    await logAdminAction(request, g.caller?.id ?? null, 'odometer_delete', 'odometer_readings', row.id,
      { user_id: row.user_id, reading_km: row.reading_km, taken_at: row.taken_at });
    return reply.send({ ok: true });
  });

  // Admin: corrige (o borra, con null) el odómetro apuntado en una CARRERA
  // (transactions.odometer_km) — la otra fuente del km de los retos. Solo toca ese
  // campo; el importe/fecha de la carrera no se alteran. Queda auditado.
  app.patch('/api/v1/admin/transactions/:id/odometer', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const body = request.body ?? {};
    let newKm = null;
    if (body.odometer_km !== null && body.odometer_km !== undefined && body.odometer_km !== '') {
      const km = Number(body.odometer_km);
      if (!Number.isFinite(km) || km < 0 || km > 100000000) {
        return reply.code(400).send({ error: 'km no válido' });
      }
      newKm = Math.round(km);
    }
    const { data: row } = await supabase.from('transactions')
      .select('id, user_id, odometer_km').eq('id', request.params.id).maybeSingle();
    if (!row) return reply.code(404).send({ error: 'Carrera no encontrada' });
    await supabase.from('transactions')
      .update({ odometer_km: newKm }).eq('id', row.id);
    await logAdminAction(request, g.caller?.id ?? null, 'odometer_correct', 'transactions', row.id,
      { user_id: row.user_id, from: row.odometer_km, to: newKm });
    return reply.send({ ok: true, odometer_km: newKm });
  });

  // Admin: corrige el km INICIAL de un vehículo (initial_odometer, y registered_km
  // por compat). Es el punto de partida del odómetro para los km de retos. Auditado.
  app.patch('/api/v1/admin/vehicles/:id/odometer', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const km = Number((request.body ?? {}).initial_odometer);
    if (!Number.isFinite(km) || km < 0 || km > 100000000) {
      return reply.code(400).send({ error: 'km no válido' });
    }
    const { data: row } = await supabase.from('vehicles')
      .select('id, initial_odometer').eq('id', request.params.id).maybeSingle();
    if (!row) return reply.code(404).send({ error: 'Vehículo no encontrado' });
    const newKm = Math.round(km);
    await supabase.from('vehicles')
      .update({ initial_odometer: newKm, registered_km: newKm }).eq('id', row.id);
    await logAdminAction(request, g.caller?.id ?? null, 'odometer_correct', 'vehicles', row.id,
      { from: row.initial_odometer, to: newKm });
    return reply.send({ ok: true, initial_odometer: newKm });
  });
}

// ============================================================
// Corrección de km por el PROPIO CLIENTE (conductor / jefe / autónomo).
// Para quien apuntó un km de más (p. ej. 324.423 en vez de 32.442): ese número
// pasa a ser el "último km" del coche y la app ya no deja apuntar menos.
// Reglas (anti-trampa de los retos de km, que suman max(km) − km inicial):
//   - SOLO se puede BAJAR un km (o borrarlo); subirlo inflaría el reto.
//   - Nunca por debajo del km inicial del vehículo.
//   - El conductor corrige los suyos; el jefe, los de toda su empresa.
//   - Cada corrección queda en admin_actions_log (odometer_self_*), con de/a.
// Va por el backend (service_role) porque la RLS de odometer_readings no deja
// editar ni borrar desde el cliente (y así se pueden imponer estas reglas).
// ============================================================

// Valida una corrección. Devuelve null si se permite o el código de error.
export function checkSelfCorrection({ caller, row, newKm, initialKm }) {
  if (!caller || !row) return 'not_found';
  if (!caller.tenant_id || row.tenant_id !== caller.tenant_id) return 'forbidden';
  if (caller.role !== 'owner' && row.user_id !== caller.id) return 'forbidden';
  if (newKm === null) return null; // borrar: nunca infla nada
  if (!Number.isInteger(newKm) || newKm < 0) return 'km_invalid';
  if (row.km != null && newKm >= row.km) return 'km_not_lower';
  if (initialKm != null && newKm < initialKm) return 'km_below_initial';
  return null;
}

const SELF_SOURCES = {
  reading: { table: 'odometer_readings', col: 'reading_km' },
  transaction: { table: 'transactions', col: 'odometer_km' },
};

export function registerOdometerSelfRoutes(app, { supabase, logAdminAction, getCaller }) {
  // Lista de km corregibles: del conductor (los suyos) o del jefe (toda la empresa).
  app.get('/api/v1/odometer/entries', async (request, reply) => {
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (!caller.tenant_id) return reply.send({ entries: [] });
    const isOwner = caller.role === 'owner';
    const limit = 80;
    let rq = supabase.from('odometer_readings')
      .select('id, user_id, vehicle_id, reading_km, taken_at, vehicles:vehicle_id(license_plate, initial_odometer)')
      .eq('tenant_id', caller.tenant_id);
    let tq = supabase.from('transactions')
      .select('id, user_id, vehicle_id, odometer_km, created_at, vehicles:vehicle_id(license_plate, initial_odometer)')
      .eq('tenant_id', caller.tenant_id).not('odometer_km', 'is', null);
    if (!isOwner) { rq = rq.eq('user_id', caller.id); tq = tq.eq('user_id', caller.id); }
    const [rd, tx] = await Promise.all([
      rq.order('taken_at', { ascending: false }).limit(limit),
      tq.order('created_at', { ascending: false }).limit(limit),
    ]);
    if (rd.error) return reply.code(500).send({ error: rd.error.message });
    if (tx.error) return reply.code(500).send({ error: tx.error.message });
    // Nombre de quién lo apuntó (solo útil al jefe).
    const names = {};
    if (isOwner) {
      const ids = [...new Set([...(rd.data ?? []), ...(tx.data ?? [])].map((r) => r.user_id).filter(Boolean))];
      if (ids.length) {
        const { data: us } = await supabase.from('users').select('id, name, email').in('id', ids);
        for (const u of us ?? []) names[u.id] = u.name || u.email || null;
      }
    }
    const map = (r, source, km, at) => ({
      source, id: r.id, km, at, vehicle_id: r.vehicle_id,
      plate: (r.vehicles || {}).license_plate ?? null,
      initial_km: (r.vehicles || {}).initial_odometer ?? null,
      user_id: r.user_id, user_name: names[r.user_id] ?? null,
    });
    const entries = [
      ...(rd.data ?? []).map((r) => map(r, 'reading', r.reading_km, r.taken_at)),
      ...(tx.data ?? []).map((t) => map(t, 'transaction', t.odometer_km, t.created_at)),
    ].sort((a, b) => new Date(b.at) - new Date(a.at)).slice(0, 120);
    return reply.send({ entries });
  });

  async function loadRow(source, id) {
    const s = SELF_SOURCES[source];
    if (!s) return null;
    const { data } = await supabase.from(s.table)
      .select(`id, tenant_id, user_id, vehicle_id, ${s.col}`).eq('id', id).maybeSingle();
    if (!data) return null;
    let initialKm = null;
    if (data.vehicle_id) {
      const { data: v } = await supabase.from('vehicles')
        .select('initial_odometer').eq('id', data.vehicle_id).maybeSingle();
      initialKm = v?.initial_odometer ?? null;
    }
    return { row: { ...data, km: data[s.col] }, initialKm, s };
  }

  const MSG = {
    not_found: [404, 'No encontrado'],
    forbidden: [403, 'No puedes corregir este km'],
    km_invalid: [400, 'km no válido'],
    km_not_lower: [400, 'Solo se puede bajar un km'],
    km_below_initial: [400, 'No puede ser menor que el km inicial del vehículo'],
  };
  const fail = (reply, code) => reply.code(MSG[code][0]).send({ error: MSG[code][1], code });

  // Corrige (solo a la BAJA) un km: lectura de jornada o km de una carrera.
  app.patch('/api/v1/odometer/entries/:source/:id', async (request, reply) => {
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    const raw = Number((request.body ?? {}).km);
    const newKm = Number.isFinite(raw) ? Math.round(raw) : NaN;
    const found = await loadRow(request.params.source, request.params.id);
    const err = checkSelfCorrection({ caller, row: found?.row, newKm, initialKm: found?.initialKm });
    if (err) return fail(reply, err);
    const { row, s } = found;
    const { error } = await supabase.from(s.table).update({ [s.col]: newKm }).eq('id', row.id);
    if (error) return reply.code(400).send({ error: error.message });
    await logAdminAction(request, caller.id, 'odometer_self_correct', s.table, row.id,
      { user_id: row.user_id, by_role: caller.role, from: row.km, to: newKm });
    return reply.send({ ok: true, km: newKm });
  });

  // Borra un km erróneo: la lectura entera, o solo el km de la carrera (la
  // carrera se queda).
  app.delete('/api/v1/odometer/entries/:source/:id', async (request, reply) => {
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    const found = await loadRow(request.params.source, request.params.id);
    const err = checkSelfCorrection({ caller, row: found?.row, newKm: null, initialKm: null });
    if (err) return fail(reply, err);
    const { row, s } = found;
    const { error } = request.params.source === 'reading'
      ? await supabase.from(s.table).delete().eq('id', row.id)
      : await supabase.from(s.table).update({ odometer_km: null }).eq('id', row.id);
    if (error) return reply.code(400).send({ error: error.message });
    await logAdminAction(request, caller.id, 'odometer_self_delete', s.table, row.id,
      { user_id: row.user_id, by_role: caller.role, km: row.km });
    return reply.send({ ok: true });
  });
}
