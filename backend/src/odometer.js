// ============================================================
// TaxiCount - Corrección de odómetro (admin). Fase B del troceig.
// Plugin de rutas: corregir/eliminar los km que alimentan los retos y el km/día,
// desde sus dos orígenes (odometer_readings de jornada + transactions.odometer_km
// de cada carrera) + el odómetro inicial del vehículo. Solo admin. Sin cambio de
// comportamiento; deps del closure inyectadas por parámetro.
// ============================================================

export function registerOdometerRoutes(app, { supabase, adminGuard, logAdminAction }) {
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
