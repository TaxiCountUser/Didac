// ============================================================
// TaxiCount - Feature flags (admin). Fase B del troceig.
// Plugin de rutas: leer/conmutar los interruptores de plataforma (system_config
// prefijo flag_). KNOWN_FLAGS (allowlist) vive aquí. Solo admin.
// NOTA: la infra de flags (loadFlags/flagOn/invalidateFlagCache/caché) se queda en
// server.js porque la comparte el procesamiento async del webhook; se inyecta.
// ============================================================

export function registerFlagsRoutes(app, {
  supabase, adminGuard, logAdminAction, flagOn, invalidateFlagCache,
}) {
  // Feature flags (M2-7): allowlist de interruptores conmutables desde el panel.
  // `webhook_async` = procesar el webhook de Stripe de forma asíncrona (ACK +
  // drenaje por cron) en vez de inline. Default OFF (comportamiento síncrono).
  const KNOWN_FLAGS = {
    webhook_async: { def: false, label: 'Procesar webhooks de Stripe en asíncrono' },
  };

  app.get('/api/v1/admin/flags', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    invalidateFlagCache();
    const flags = {};
    for (const name of Object.keys(KNOWN_FLAGS)) {
      flags[name] = { on: await flagOn(name, KNOWN_FLAGS[name].def), label: KNOWN_FLAGS[name].label };
    }
    return reply.send({ flags });
  });

  app.post('/api/v1/admin/flags', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { name, on } = request.body ?? {};
    if (!Object.prototype.hasOwnProperty.call(KNOWN_FLAGS, name)) {
      return reply.code(400).send({ error: 'Flag desconocido' });
    }
    const value = (on === true || on === 'true' || on === 'on' || on === '1') ? 'on' : 'off';
    try {
      await supabase.from('system_config').upsert(
        { key: `flag_${name}`, value }, { onConflict: 'key' });
    } catch (e) {
      return reply.code(500).send({ error: `No se pudo guardar el flag: ${e.message}` });
    }
    invalidateFlagCache();
    await logAdminAction(request, g.caller?.id ?? null, 'flag_set', 'feature_flag', name, { name, value });
    return reply.send({ ok: true, name, on: value === 'on' });
  });
}
