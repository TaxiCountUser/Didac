// ============================================================
// TaxiCount - Endpoint de métricas de uso (admin). Fase B del troceig.
// GET /admin/metrics: actividad de entrada (voz/manual), uso de Groq (rate-limit en
// vivo por modelo) y recursos de Supabase (CPU/RAM/disco). groqUsage/groqModelPct e
// inputActivity viven aquí (metrics-only). supabaseMetrics se INYECTA: se queda en
// server.js porque también lo llama el cron/vigía de semáforos (foto de recursos).
// Solo admin, solo lectura. Cifras de PLATAFORMA, nunca datos de clientes.
// ============================================================

export function registerMetricsRoutes(app, { supabase, adminGuard, supabaseMetrics }) {
  // ── Monitor de uso: Groq (rate-limit en vivo) + recursos de Supabase ───────
  // Uso de Groq: % RESTANTE del recurso más ajustado (peticiones o tokens) según
  // la última foto de cabeceras (svc_groq_rl). <20% restante => alerta.
  // % restante por modelo (el recurso más ajustado: peticiones o tokens).
  function groqModelPct(s) {
    const pcts = [];
    if (s.lim_req > 0 && s.rem_req != null) pcts.push(s.rem_req / s.lim_req);
    if (s.lim_tok > 0 && s.rem_tok != null) pcts.push(s.rem_tok / s.lim_tok);
    return pcts.length ? Math.round(Math.min(...pcts) * 100) : null;
  }

  async function groqUsage() {
    try {
      const { data } = await supabase.from('system_config')
        .select('key, value').like('key', 'svc_groq_rl%');
      // Dedup por modelo (quedándonos con la foto más reciente); incluye la clave
      // antigua 'svc_groq_rl' (foto única) por compatibilidad.
      const byModel = {};
      for (const r of data ?? []) {
        let s; try { s = JSON.parse(r.value); } catch { continue; }
        const model = s.model || r.key.replace('svc_groq_rl:', '') || '?';
        if (!byModel[model] || new Date(s.at) > new Date(byModel[model].at)) byModel[model] = s;
      }
      const models = Object.entries(byModel).map(([model, s]) => ({
        model, at: s.at, remaining_pct: groqModelPct(s),
        requests: { remaining: s.rem_req, limit: s.lim_req },
        tokens: { remaining: s.rem_tok, limit: s.lim_tok },
      })).filter((m) => m.remaining_pct != null)
        .sort((a, b) => a.remaining_pct - b.remaining_pct);
      if (!models.length) return { available: false };
      // remaining_pct global = el modelo más ajustado (para el resumen/semáforo).
      return { available: true, remaining_pct: models[0].remaining_pct, models };
    } catch { return { available: false }; }
  }

  // vs a MANO (columna transactions.source, mig. 080). Es el indicador de ACTIVIDAD
  // real (a diferencia del rate-limit de Groq, que es margen y siempre está casi
  // lleno). Solo RECUENTOS agregados de plataforma (nunca importes): coherente con
  // la protección de datos del panel. 'unknown' = filas previas a la mig. 080.
  async function inputActivity() {
    try {
      const startToday = new Date(); startToday.setUTCHours(0, 0, 0, 0);
      const iso = startToday.toISOString();
      const countSrc = async (src) => {
        const { count } = await supabase.from('transactions')
          .select('id', { count: 'exact', head: true })
          .gte('created_at', iso).eq('source', src);
        return count ?? 0;
      };
      const [voice, manual] = await Promise.all([countSrc('voice'), countSrc('manual')]);
      return { available: true, voice_today: voice, manual_today: manual };
    } catch { return { available: false }; }
  }

  // Monitor de uso: actividad de entrada (voz/manual) + Groq (rate-limit en vivo) +
  // recursos de Supabase (CPU/RAM/disco + tamaño BD y conexiones). Refresca el
  // scrape en cada consulta.
  app.get('/api/v1/admin/metrics', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const [groq, supa, activity] = await Promise.all([
      groqUsage(), supabaseMetrics(), inputActivity(),
    ]);
    return reply.send({ groq, supabase: supa, activity });
  });
}
