// ============================================================
// TaxiCount - Capa B de seguridad: registro de eventos.
// logSecurityEvent inserta en la tabla `security_events` (login fallido,
// token inválido, rate-limit, escalada de privilegios, incidentes reportados
// por el cliente…). Es un helper PURO: solo depende de `supabase` y `log`.
// Extraído de server.js (Fase A del troceig) sin cambio de comportamiento;
// se instancia con createSecurityLog({ supabase, log }) dentro de buildApp().
// ============================================================

export function createSecurityLog({ supabase, log }) {
  async function logSecurityEvent(request, eventType, opts = {}) {
    if (!supabase) return;
    try {
      await supabase.from('security_events').insert({
        event_type: eventType,
        actor_id: opts.actorId ?? null,
        tenant_id: opts.tenantId ?? null,
        ip_address: request?.ip ?? null,
        user_agent: (request?.headers?.['user-agent'] ?? '').slice(0, 300) || null,
        method: request?.method ?? null,
        path: (request?.url || '').split('?')[0].slice(0, 200) || null,
        status_code: opts.status ?? null,
        trace_id: request?.id ?? null,
        details: opts.details ?? null,
      });
    } catch (e) {
      log.warn(`[security] no se pudo registrar ${eventType}: ${e.message}`);
    }
  }

  return { logSecurityEvent };
}
