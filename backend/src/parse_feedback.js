// ============================================================
// TaxiCount - Feedback del parseo por voz (pestaña "Parseig" de Monitorización).
//
// /transcribe guarda por cada dictado lo que propuso cada etapa (record) y la app,
// al GUARDAR, envía los valores finales (POST /parse-feedback/:id/saved). Aquí se
// compara campo a campo y se clasifica cada corrección:
//   kind : missing (no se detectó) | wrong (se detectó mal) | extra (sobraba)
//   stage: merge          -> el determinista o el LLM lo tenían bien, la mezcla no
//          interpretation -> el texto estaba bien pero ninguno lo sacó
//          transcription  -> el valor ni aparece en el texto (Whisper lo oyó mal;
//                            solo se puede saber en campos de texto: ruta/empresa)
// Tabla parse_feedback (mig. 086), solo service_role. Retención 90 días.
// ============================================================

export const FEEDBACK_FIELDS = [
  'type', 'amount', 'payment_method', 'category', 'origin', 'destination', 'client_name', 'odometer_km',
];
const TEXT_FIELDS = new Set(['origin', 'destination', 'client_name']);
const RETENTION_DAYS = 90;
// Un dictado sin guardar pasado este tiempo cuenta como abandonado.
const ABANDON_MS = 30 * 60 * 1000;

const norm = (s) => String(s ?? '').toLowerCase().normalize('NFD')
  .replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9·'’ ]+/g, ' ').replace(/\s+/g, ' ').trim();

// Valor "vacío" para comparar: null/''/0 en el importe (0 = "no se dijo").
function clean(field, v) {
  if (v == null || v === '') return null;
  if (field === 'amount' || field === 'odometer_km') {
    const n = Number(v);
    return Number.isFinite(n) && n !== 0 ? n : null;
  }
  if (field === 'category' && v === 'ingreso_tarjeta') return null; // categoría genérica
  return TEXT_FIELDS.has(field) ? (norm(v) || null) : String(v);
}
function same(field, a, b) {
  const x = clean(field, a);
  const y = clean(field, b);
  if (x == null || y == null) return x === y;
  if (field === 'amount') return Math.abs(x - y) < 0.005;
  return x === y;
}

function levenshtein(a, b) {
  let prev = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    for (let j = 1; j <= b.length; j++) {
      cur[j] = Math.min(cur[j - 1] + 1, prev[j] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
    prev = cur;
  }
  return prev[b.length];
}

// ¿Aparece el valor guardado en el texto? Cada palabra significativa (3+ letras)
// debe estar en el texto, tolerando una letra de diferencia.
function appearsInText(value, text) {
  const words = norm(value).split(' ').filter((w) => w.length >= 3);
  if (!words.length) return true;
  const toks = norm(text).split(' ');
  return words.every((w) => toks.some((t) => t === w || (w.length >= 5 && levenshtein(t, w) <= 1)));
}

/**
 * Compara lo propuesto con lo guardado. Devuelve { campo: {proposed, saved, kind, stage} }
 * solo con los campos corregidos. Los campos de ruta/empresa solo cuentan en ingresos.
 */
export function classifyCorrections({ text, det, llm, proposed, saved }) {
  const out = {};
  const isIncome = (saved?.type ?? proposed?.type) !== 'expense';
  for (const f of FEEDBACK_FIELDS) {
    if (!saved || !(f in saved)) continue;
    if ((TEXT_FIELDS.has(f)) && !isIncome) continue;
    if (f === 'category' && isIncome) continue;
    const p = proposed?.[f];
    const s = saved[f];
    if (same(f, p, s)) continue;
    const pc = clean(f, p);
    const sc = clean(f, s);
    const kind = pc == null ? 'missing' : sc == null ? 'extra' : 'wrong';
    let stage = 'interpretation';
    if (sc != null && (same(f, det?.[f], s) || (llm && same(f, llm[f], s)))) stage = 'merge';
    else if (sc != null && TEXT_FIELDS.has(f) && !appearsInText(s, text)) stage = 'transcription';
    out[f] = { proposed: p ?? null, saved: s ?? null, kind, stage };
  }
  return out;
}

/** Helper del closure: guardar el traza de un dictado (best-effort, nunca lanza). */
export function createParseFeedback({ supabase, log }) {
  let lastPurge = 0;
  async function purgeOld() {
    if (Date.now() - lastPurge < 24 * 3600 * 1000) return;
    lastPurge = Date.now();
    const cutoff = new Date(Date.now() - RETENTION_DAYS * 24 * 3600 * 1000).toISOString();
    const { error } = await supabase.from('parse_feedback').delete().lt('created_at', cutoff);
    if (error) log?.warn?.(`parse_feedback purge falló (${error.message})`);
  }
  async function recordParse(caller, { raw, text, language, trace, proposed }) {
    if (!supabase || !caller) return null;
    try {
      const { data, error } = await supabase.from('parse_feedback').insert({
        tenant_id: caller.tenant_id ?? null,
        user_id: caller.id,
        language: language ?? null,
        raw_text: raw ?? null,
        text: text ?? null,
        det: trace?.det ?? null,
        llm: trace?.llm ?? null,
        llm_skipped: !!trace?.llm_skipped,
        llm_error: trace?.llm_error ?? null,
        llm_ms: trace?.llm_ms ?? null,
        proposed: proposed ?? null,
      }).select('id').single();
      if (error) throw error;
      purgeOld().catch(() => {});
      return data.id;
    } catch (e) {
      log?.warn?.(`parse_feedback insert falló (${e.message})`);
      return null;
    }
  }
  return { recordParse };
}

export function registerParseFeedbackRoutes(app, { supabase, getCaller, adminGuard }) {
  // La app, al guardar un registro dictado, envía los valores finales.
  app.post('/api/v1/parse-feedback/:id/saved', async (request, reply) => {
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    const { id } = request.params;
    const body = request.body || {};
    const saved = {};
    for (const f of FEEDBACK_FIELDS) if (f in (body.saved || {})) saved[f] = body.saved[f];
    const { data: row, error } = await supabase.from('parse_feedback')
      .select('id, user_id, text, det, llm, proposed, status').eq('id', id).maybeSingle();
    if (error) return reply.code(500).send({ error: error.message });
    // Solo el autor del dictado, y una sola vez.
    if (!row || row.user_id !== caller.id) return reply.code(404).send({ error: 'No encontrado' });
    if (row.status === 'saved') return reply.send({ ok: true, already: true });
    const corrections = classifyCorrections({ text: row.text, det: row.det, llm: row.llm, proposed: row.proposed, saved });
    const { error: e2 } = await supabase.from('parse_feedback')
      .update({ saved, corrections, status: 'saved', saved_at: new Date().toISOString() })
      .eq('id', id);
    if (e2) return reply.code(500).send({ error: e2.message });
    return reply.send({ ok: true, corrected: Object.keys(corrections) });
  });

  // Resumen para la pestaña "Parseig": ?days=7 (1..90).
  app.get('/api/v1/admin/parse-feedback/summary', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const days = Math.min(Math.max(parseInt(request.query?.days ?? '7', 10) || 7, 1), RETENTION_DAYS);
    const since = new Date(Date.now() - days * 24 * 3600 * 1000).toISOString();
    const { data, error } = await supabase.from('parse_feedback')
      .select('status, created_at, llm_skipped, llm_error, llm_ms, corrections')
      .gte('created_at', since).order('created_at', { ascending: false }).limit(5000);
    if (error) return reply.code(500).send({ error: error.message });
    const rows = data ?? [];
    const now = Date.now();
    const fields = Object.fromEntries(FEEDBACK_FIELDS.map((f) => [f, {
      corrected: 0, missing: 0, wrong: 0, extra: 0, merge: 0, interpretation: 0, transcription: 0,
    }]));
    let saved = 0; let clean = 0; let abandoned = 0; let pending = 0;
    let llmUsed = 0; let llmErrors = 0; let llmMsSum = 0; let llmMsN = 0;
    for (const r of rows) {
      if (r.status === 'saved') {
        saved++;
        const c = r.corrections || {};
        if (!Object.keys(c).length) clean++;
        for (const [f, v] of Object.entries(c)) {
          const s = fields[f];
          if (!s) continue;
          s.corrected++;
          if (s[v.kind] != null) s[v.kind]++;
          if (s[v.stage] != null) s[v.stage]++;
        }
      } else if (now - new Date(r.created_at).getTime() > ABANDON_MS) abandoned++;
      else pending++;
      if (!r.llm_skipped) {
        llmUsed++;
        if (r.llm_error) llmErrors++;
        else if (r.llm_ms != null) { llmMsSum += r.llm_ms; llmMsN++; }
      }
    }
    return reply.send({
      days,
      total: rows.length,
      saved,
      clean,
      abandoned,
      pending,
      llm_used: llmUsed,
      llm_errors: llmErrors,
      llm_avg_ms: llmMsN ? Math.round(llmMsSum / llmMsN) : null,
      fields,
      truncated: rows.length >= 5000,
    });
  });

  // Últimos dictados (?only=corrected|abandoned|all, ?limit=50).
  app.get('/api/v1/admin/parse-feedback', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const qp = request.query ?? {};
    const limit = Math.min(Math.max(parseInt(qp.limit ?? '50', 10) || 50, 1), 200);
    const only = qp.only || 'corrected';
    let q = supabase.from('parse_feedback')
      .select('id, created_at, saved_at, status, language, raw_text, text, det, llm, llm_skipped, '
        + 'llm_error, llm_ms, proposed, saved, corrections, tenant:tenant_id(name)')
      .order('created_at', { ascending: false });
    if (only === 'corrected') q = q.eq('status', 'saved').neq('corrections', '{}');
    if (only === 'abandoned') {
      q = q.eq('status', 'pending').lt('created_at', new Date(Date.now() - ABANDON_MS).toISOString());
    }
    const { data, error } = await q.limit(limit);
    if (error) return reply.code(500).send({ error: error.message });
    return reply.send({ items: data ?? [] });
  });
}
