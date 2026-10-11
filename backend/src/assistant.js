// ============================================================
// TaxiCount - Asistente virtual (bot de preguntas frecuentes, SIN IA ni tokens).
//
// El motor corre en la app (frontend/lib/assistant/). La semilla de respuestas va
// en el asset kb.json; aquí solo:
//   · GET  /assistant/kb        -> respuestas del admin + frases aprendidas
//   · POST /assistant/log       -> registra una pregunta y lo que respondió el bot
//   · POST /assistant/feedback  -> "me ha servido" / "no"; si sirvió tras no
//                                  entender, APRENDE las frases previas (auto)
//   · /admin/assistant/*        -> panel: resumen, preguntas sin respuesta,
//                                  enseñar frases, crear/editar/ocultar respuestas
// Tablas (mig. 087), solo service_role. Retención de queries 180 días.
// ============================================================

const RETENTION_DAYS = 180;
const MAX_Q = 300;          // longitud máxima de una pregunta
const MAX_LEARN = 3;        // frases que se aprenden de una vez
const OUTCOMES = new Set(['answered', 'no_match', 'helpful', 'not_helpful', 'ticket']);
const ID_RE = /^[a-z0-9_]{2,60}$/;

// MISMA normalización que la app (assistant_engine.dart → normalize): minúsculas,
// sin acentos, solo letras/números, espacios simples.
export const normPhrase = (s) => String(s ?? '').toLowerCase().normalize('NFD')
  .replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9ñç ]+/g, ' ')
  .replace(/\s+/g, ' ').trim().slice(0, MAX_Q);

/** Valida/sanea la definición de una respuesta que envía el admin. */
export function cleanEntry(d) {
  if (!d || typeof d !== 'object') return null;
  const txt = (v, n) => (typeof v === 'string' ? v.trim().slice(0, n) : '');
  const byLang = (o, fn) => {
    const out = {};
    for (const l of ['es', 'ca', 'en']) {
      const v = fn(o?.[l]);
      if (v && (!Array.isArray(v) || v.length)) out[l] = v;
    }
    return out;
  };
  const list = (v) => (Array.isArray(v) ? v : String(v ?? '').split('\n'))
    .map((x) => txt(x, 200)).filter(Boolean).slice(0, 40);
  const a = byLang(d.a, (v) => txt(v, 2000));
  if (!a.es) return null; // como mínimo la respuesta en español
  const roles = Array.isArray(d.roles) ? d.roles.filter((r) => ['driver', 'owner', 'solo'].includes(r)) : [];
  const tutorial = txt(d.tutorial, 500);
  return {
    cat: txt(d.cat, 40) || 'general',
    roles,
    q: byLang(d.q, list),
    a,
    action: txt(d.action, 40) || null,
    tutorial: /^https?:\/\//.test(tutorial) ? tutorial : null,
    related: Array.isArray(d.related) ? d.related.filter((x) => ID_RE.test(x)).slice(0, 5) : [],
  };
}

export function registerAssistantRoutes(app, { supabase, getCaller, adminGuard, logAdminAction }) {
  // ---------- App ----------

  app.get('/api/v1/assistant/kb', async (request, reply) => {
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    const [{ data: entries, error: e1 }, { data: learned, error: e2 }] = await Promise.all([
      supabase.from('assistant_entries').select('id, data, active'),
      supabase.from('assistant_learned').select('phrase, entry_id, lang').limit(5000),
    ]);
    if (e1 || e2) return reply.code(500).send({ error: (e1 || e2).message });
    return reply.send({ entries: entries ?? [], learned: learned ?? [] });
  });

  app.post('/api/v1/assistant/log', async (request, reply) => {
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    const b = request.body ?? {};
    const question = String(b.question ?? '').trim().slice(0, MAX_Q);
    if (!question) return reply.code(400).send({ error: 'Pregunta vacía' });
    const outcome = OUTCOMES.has(b.outcome) ? b.outcome : 'answered';
    const { data, error } = await supabase.from('assistant_queries').insert({
      conversation_id: /^[0-9a-f-]{36}$/i.test(b.conversation_id ?? '') ? b.conversation_id : null,
      tenant_id: caller.tenant_id || null,
      user_id: caller.id,
      role: caller.role,
      lang: String(b.lang ?? '').slice(0, 5) || null,
      question,
      phrase: normPhrase(question),
      matched_id: typeof b.matched_id === 'string' && ID_RE.test(b.matched_id) ? b.matched_id : null,
      score: Number.isFinite(Number(b.score)) ? Number(b.score) : null,
      outcome,
    }).select('id').single();
    if (error) return reply.code(500).send({ error: error.message });
    return reply.send({ id: data.id });
  });

  // helpful=true y learn=[preguntas previas no entendidas] -> se aprenden como
  // sinónimos de la respuesta que SÍ sirvió.
  app.post('/api/v1/assistant/feedback', async (request, reply) => {
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    const b = request.body ?? {};
    const { data: row, error } = await supabase.from('assistant_queries')
      .select('id, user_id, matched_id, lang').eq('id', String(b.id ?? '')).maybeSingle();
    if (error) return reply.code(500).send({ error: error.message });
    if (!row || row.user_id !== caller.id) return reply.code(404).send({ error: 'No encontrado' });
    const helpful = b.helpful === true;
    await supabase.from('assistant_queries')
      .update({ outcome: helpful ? 'helpful' : 'not_helpful' }).eq('id', row.id);
    let learned = 0;
    if (helpful && row.matched_id && Array.isArray(b.learn)) {
      const phrases = [...new Set(b.learn.map(normPhrase))]
        .filter((p) => p.length >= 6 && p.split(' ').length >= 2).slice(0, MAX_LEARN);
      for (const phrase of phrases) {
        const { data: ex } = await supabase.from('assistant_learned')
          .select('id, hits').eq('phrase', phrase).eq('entry_id', row.matched_id).maybeSingle();
        const r = ex
          ? await supabase.from('assistant_learned')
            .update({ hits: ex.hits + 1, updated_at: new Date().toISOString() }).eq('id', ex.id)
          : await supabase.from('assistant_learned')
            .insert({ phrase, entry_id: row.matched_id, lang: row.lang, source: 'auto' });
        if (!r.error) learned++;
      }
    }
    return reply.send({ ok: true, learned });
  });

  // ---------- Admin ----------

  // Resumen + preguntas que NO supo responder (agrupadas por frase normalizada).
  app.get('/api/v1/admin/assistant/summary', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const days = Math.min(Math.max(parseInt(request.query?.days ?? '30', 10) || 30, 1), RETENTION_DAYS);
    const since = new Date(Date.now() - days * 86400000).toISOString();
    // Purga oportunista de lo que pasa de la retención.
    await supabase.from('assistant_queries').delete()
      .lt('created_at', new Date(Date.now() - RETENTION_DAYS * 86400000).toISOString());
    const { data, error } = await supabase.from('assistant_queries')
      .select('question, phrase, matched_id, outcome, lang, created_at')
      .gte('created_at', since).order('created_at', { ascending: false }).limit(5000);
    if (error) return reply.code(500).send({ error: error.message });
    const rows = data ?? [];
    const count = (o) => rows.filter((r) => r.outcome === o).length;
    const unanswered = new Map();
    const topEntries = new Map();
    for (const r of rows) {
      if (r.matched_id) topEntries.set(r.matched_id, (topEntries.get(r.matched_id) ?? 0) + 1);
      if (r.outcome !== 'no_match' && r.outcome !== 'not_helpful') continue;
      const k = r.phrase || normPhrase(r.question);
      const u = unanswered.get(k) ?? { phrase: k, example: r.question, lang: r.lang, count: 0, last: r.created_at, gave: r.matched_id };
      u.count++;
      unanswered.set(k, u);
    }
    // Las que ya se han enseñado no salen como pendientes.
    const { data: learned } = await supabase.from('assistant_learned').select('phrase');
    const taught = new Set((learned ?? []).map((l) => l.phrase));
    return reply.send({
      days,
      total: rows.length,
      answered: rows.filter((r) => r.matched_id).length,
      no_match: count('no_match'),
      helpful: count('helpful'),
      not_helpful: count('not_helpful'),
      tickets: count('ticket'),
      unanswered: [...unanswered.values()].filter((u) => !taught.has(u.phrase))
        .sort((a, b) => b.count - a.count).slice(0, 100),
      top: [...topEntries.entries()].sort((a, b) => b[1] - a[1]).slice(0, 15)
        .map(([id, n]) => ({ id, count: n })),
    });
  });

  app.get('/api/v1/admin/assistant/entries', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const [{ data: entries, error: e1 }, { data: learned, error: e2 }] = await Promise.all([
      supabase.from('assistant_entries').select('id, data, active, updated_at'),
      supabase.from('assistant_learned').select('id, phrase, entry_id, lang, source, hits, created_at')
        .order('created_at', { ascending: false }).limit(2000),
    ]);
    if (e1 || e2) return reply.code(500).send({ error: (e1 || e2).message });
    return reply.send({ entries: entries ?? [], learned: learned ?? [] });
  });

  // Crea o sustituye una respuesta (también para "editar" una de la semilla).
  app.put('/api/v1/admin/assistant/entries/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const id = String(request.params.id ?? '');
    if (!ID_RE.test(id)) return reply.code(400).send({ error: 'id inválido (a-z, 0-9, _)' });
    const body = request.body ?? {};
    const active = body.active !== false;
    // Ocultar una entrada de la semilla no necesita datos completos.
    const data = cleanEntry(body.data) ?? (active ? null : { hidden: true, a: {} });
    if (!data) return reply.code(400).send({ error: 'Falta la respuesta en español' });
    const { error } = await supabase.from('assistant_entries').upsert({
      id, data, active, updated_by: g.caller.id, updated_at: new Date().toISOString(),
    });
    if (error) return reply.code(500).send({ error: error.message });
    await logAdminAction(request, g.caller.id, 'assistant_entry_upsert', 'assistant_entries', id, { active });
    return reply.send({ ok: true });
  });

  // Borra la versión del admin (si era de la semilla, vuelve la original).
  app.delete('/api/v1/admin/assistant/entries/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { error } = await supabase.from('assistant_entries').delete().eq('id', String(request.params.id ?? ''));
    if (error) return reply.code(500).send({ error: error.message });
    await logAdminAction(request, g.caller.id, 'assistant_entry_delete', 'assistant_entries', String(request.params.id ?? ''), null);
    return reply.send({ ok: true });
  });

  // Enseñar: esta frase (sin respuesta) -> esta respuesta existente.
  app.post('/api/v1/admin/assistant/teach', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const phrase = normPhrase(request.body?.phrase);
    const entryId = String(request.body?.entry_id ?? '');
    if (!phrase || !ID_RE.test(entryId)) return reply.code(400).send({ error: 'Datos inválidos' });
    const { error } = await supabase.from('assistant_learned').upsert(
      { phrase, entry_id: entryId, lang: request.body?.lang ?? null, source: 'admin', updated_at: new Date().toISOString() },
      { onConflict: 'phrase,entry_id' },
    );
    if (error) return reply.code(500).send({ error: error.message });
    return reply.send({ ok: true });
  });

  // Olvidar una frase aprendida (si el bot aprendió algo mal).
  app.delete('/api/v1/admin/assistant/learned/:id', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { error } = await supabase.from('assistant_learned').delete().eq('id', String(request.params.id ?? ''));
    if (error) return reply.code(500).send({ error: error.message });
    return reply.send({ ok: true });
  });

  // Descartar una pregunta sin respuesta (ruido: "hola", insultos…).
  app.post('/api/v1/admin/assistant/dismiss', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const phrase = normPhrase(request.body?.phrase);
    if (!phrase) return reply.code(400).send({ error: 'Datos inválidos' });
    const { error } = await supabase.from('assistant_queries')
      .update({ outcome: 'answered' }).eq('phrase', phrase).in('outcome', ['no_match', 'not_helpful']);
    if (error) return reply.code(500).send({ error: error.message });
    return reply.send({ ok: true });
  });
}
