// ============================================================
// TaxiCount - Monitorización (semáforos + uptime). Fase A del troceig.
// - markService: registra ok/err de un servicio externo (fire-and-forget) para
//   los semáforos del panel + histórico de uptime (service_status_log).
// - computeSemaphores: estado de todos los semáforos (cron/servicios/webhooks/
//   Groq/recursos), compartido por el endpoint de admin y el vigía externo.
// - readServiceUptime: uptime % 24h/7d por servicio (privado, lo usa el anterior).
//
// Helper PURO extraído sin cambio de comportamiento: factory
// createMonitoring({ supabase, log, probeDb }). `pushEnabled` se importa directo
// (es puro); `probeDb` se inyecta porque también lo usa /overview en server.js.
// ============================================================

import { pushEnabled } from './push.js';

export function createMonitoring({ supabase, log, probeDb }) {
  // Registra el resultado (ok/err) de la última llamada a un servicio externo
  // —whisper (transcripción) u openai (parser LLM)— para los semáforos del panel
  // de admin. Guarda "ok|<iso>" o "err|<iso>". Best-effort y sin await en el hot
  // path (fire-and-forget): nunca ralentiza ni rompe la transcripción.
  function markService(name, ok) {
    supabase.from('system_config').upsert(
      { key: `svc_${name}`, value: `${ok ? 'ok' : 'err'}|${new Date().toISOString()}` },
      { onConflict: 'key' },
    ).then(({ error }) => {
      if (error) log.warn(`[svc] no se pudo registrar svc_${name}: ${error.message}`);
    }, (e) => log.warn(`[svc] svc_${name}: ${e.message}`));
    // Histórico para uptime % (mig. 079). Best-effort: si la tabla no está, se ignora.
    supabase.from('service_status_log').insert({ service: name, ok })
      .then(() => {}, () => {});
  }

  // Uptime % por servicio desde service_status_log (mig. 079): ok/total en 24h y 7d.
  // Una sola consulta (7d) y se agrega en JS. Limpieza oportunista de >90 días.
  async function readServiceUptime() {
    const out = {};
    try {
      const now = Date.now();
      const since7 = new Date(now - 7 * 24 * 3600 * 1000).toISOString();
      const since24 = now - 24 * 3600 * 1000;
      const { data } = await supabase.from('service_status_log')
        .select('service, ok, checked_at').gte('checked_at', since7).limit(50000);
      const agg = {};
      for (const r of data ?? []) {
        const a = (agg[r.service] ??= { ok7: 0, n7: 0, ok24: 0, n24: 0 });
        a.n7 += 1; if (r.ok) a.ok7 += 1;
        if (new Date(r.checked_at).getTime() >= since24) { a.n24 += 1; if (r.ok) a.ok24 += 1; }
      }
      for (const [svc, a] of Object.entries(agg)) {
        out[svc] = {
          up24: a.n24 ? +((a.ok24 / a.n24) * 100).toFixed(1) : null,
          up7: a.n7 ? +((a.ok7 / a.n7) * 100).toFixed(1) : null,
          n7: a.n7,
        };
      }
      supabase.from('service_status_log')
        .delete().lt('checked_at', new Date(now - 90 * 24 * 3600 * 1000).toISOString())
        .then(() => {}, () => {});
    } catch (e) {
      log.warn(`[uptime] ${e.message}`);
    }
    return out;
  }

  // Calcula el estado de todos los semáforos (compartido por el endpoint de
  // admin y el del vigía externo). Lee system_config (cron_last_* y svc_*) y
  // devuelve, por cada semáforo, su último resultado y cuándo fue. Estados:
  //   ok     verde (cron reciente <48h, o servicio cuya última llamada fue OK)
  //   stale  rojo  (cron sin ejecutarse hace >=48h)
  //   error  rojo  (servicio cuya última llamada falló)
  //   never  gris  (aún sin datos)
  //   live   verde (API: si respondemos, está viva)
  async function computeSemaphores({ logHistory = false } = {}) {
    const cfg = {};
    for (const pat of ['cron_last_%', 'svc_%']) {
      const { data: rows } = await supabase.from('system_config')
        .select('key, value').like('key', pat);
      for (const r of rows ?? []) cfg[r.key] = r.value;
    }
    const now = Date.now();
    const FRESH_MS = 48 * 60 * 60 * 1000;

    const cronSema = (key) => {
      const at = cfg[`cron_last_${key}`] || null;
      if (!at) return { key, kind: 'cron', ok: false, at: null, status: 'never' };
      const stale = now - new Date(at).getTime() > FRESH_MS;
      return { key, kind: 'cron', ok: !stale, at, status: stale ? 'stale' : 'ok' };
    };
    const svcSema = (key) => {
      const raw = cfg[`svc_${key}`];
      if (!raw) return { key, kind: 'service', ok: true, at: null, status: 'never' };
      const [st, at] = String(raw).split('|');
      const isErr = st === 'err';
      // Un error ANTIGUO (>24 h) deja de alertar: un fallo puntual (p. ej. un
      // evento de prueba de Stripe con otro secreto, o una llamada suelta a
      // Whisper) no debe dejar el semáforo en rojo para siempre. La próxima
      // llamada correcta lo pone verde; mientras, no gritamos por algo viejo.
      const recent = at && (now - new Date(at).getTime() < 24 * 60 * 60 * 1000);
      const err = isErr && recent;
      return { key, kind: 'service', ok: !err, at: at || null,
        status: err ? 'error' : (isErr ? 'idle' : 'ok') };
    };

    // La purga de retención NO es un cron periódico (se ejecuta a lo sumo una vez
    // al año); mostramos su última ejecución sin marcarla en rojo por antigüedad.
    const purgeAt = cfg['cron_last_purge_retention'] || null;
    const purgeSema = { key: 'purge_retention', kind: 'cron_rare', ok: true,
      at: purgeAt, status: purgeAt ? 'ok' : 'never' };

    // Push: si FCM NO está configurado (sin service account), el semáforo es
    // "off" (gris, sin alerta): apagado a propósito no es una avería. Un error
    // antiguo registrado en svc_push tampoco debe alertar en ese caso.
    const pushSema = pushEnabled()
      ? svcSema('push')
      : { key: 'push', kind: 'service', ok: true, at: null, status: 'off' };

    // Bandeja de webhooks (Mes 2, M2-6/M2-8): eventos de Stripe sin aplicar.
    //  - 'error'+'dead' = rotos (cobro/cancelación sin reflejar) → rojo;
    //  - 'received' atascados (>10 min) = backlog: el drenaje async no avanza → rojo.
    // Si la tabla aún no existe, "off".
    let webhookSema = { key: 'webhook_errors', kind: 'count', ok: true, at: null, status: 'off' };
    try {
      const stuckCutoff = new Date(now - 10 * 60 * 1000).toISOString();
      const [brokenRes, stuckRes] = await Promise.all([
        supabase.from('webhook_events').select('event_id', { count: 'exact', head: true })
          .in('status', ['error', 'dead']),
        supabase.from('webhook_events').select('event_id', { count: 'exact', head: true })
          .eq('status', 'received').lt('received_at', stuckCutoff),
      ]);
      const broken = brokenRes.count ?? 0;
      const stuck = stuckRes.count ?? 0;
      const n = broken + stuck;
      webhookSema = { key: 'webhook_errors', kind: 'count', ok: n === 0,
        at: new Date().toISOString(), status: n === 0 ? 'ok' : 'error',
        count: n, broken, stuck };
    } catch { /* tabla webhook_events puede no existir aún en prod */ }

    // Groq: % restante en vivo por modelo (svc_groq_rl:*). El semáforo toma el
    // modelo más ajustado; < 20% restante -> rojo. PERO el límite de tokens de Groq
    // es POR MINUTO y el snapshot SOLO se actualiza al llamar a Groq: una lectura
    // vieja (sin uso reciente) NO refleja el estado actual. Por eso, si el dato no
    // es reciente, se marca "stale" (sin alarma) en vez de quedarse en rojo con un
    // valor caducado de un pico puntual. Coherente con svcSema (ignora >24 h).
    // El semáforo alarma SOLO por el margen de PETICIONES (la cuota que de verdad
    // se agota; whisper y llama la reportan). El margen de TOKENS es POR MINUTO y
    // se rellena solo, así que baja justo tras una llamada → daba falsos rojos;
    // aquí es solo informativo (`tokens_pct`), nunca pone rojo. Además, si la
    // lectura de peticiones no es reciente (sin uso), no alarma (stale).
    const GROQ_FRESH_MS = 15 * 60 * 1000;
    let groqSema = { key: 'groq', kind: 'usage', ok: true, at: null, status: 'off' };
    try {
      let minReq = null; let atMin = null; let tokPct = null;
      for (const k of Object.keys(cfg)) {
        if (!k.startsWith('svc_groq_rl')) continue;
        let s; try { s = JSON.parse(cfg[k]); } catch { continue; }
        if (s.lim_req > 0 && s.rem_req != null) {
          const p = Math.round((s.rem_req / s.lim_req) * 100);
          if (minReq == null || p < minReq) { minReq = p; atMin = s.at; }
        }
        if (s.lim_tok > 0 && s.rem_tok != null) {
          const t = Math.round((s.rem_tok / s.lim_tok) * 100);
          if (tokPct == null || t < tokPct) tokPct = t;
        }
      }
      if (minReq != null) {
        const fresh = atMin && (now - new Date(atMin).getTime() < GROQ_FRESH_MS);
        groqSema = { key: 'groq', kind: 'usage',
          ok: fresh ? minReq >= 20 : true,
          at: atMin,
          status: !fresh ? 'stale' : (minReq >= 20 ? 'ok' : 'error'),
          remaining_pct: minReq, tokens_pct: tokPct };
      }
    } catch { /* svc_groq_rl* ausente o no parseable */ }

    // Recursos de Supabase (svc_supabase_res): CPU/RAM/disco > 80% -> rojo.
    let supaResSema = { key: 'supabase_res', kind: 'usage', ok: true, at: null, status: 'off' };
    try {
      const raw = cfg['svc_supabase_res'];
      if (raw) {
        const s = JSON.parse(raw);
        const vals = [s.ram_pct, s.disk_pct, s.cpu_pct].filter((x) => typeof x === 'number');
        if (vals.length) {
          const max = Math.max(...vals);
          // Umbral 80% para RAM/CPU. Para DISCO, 90%: en el plan GRATIS de Supabase
          // el disco de la instancia va alto de base (Postgres+servicios) al margen
          // de que la BD sea de pocos MB, así que <90% no es una avería accionable
          // (el arreglo real es Free→Pro). >=90% sí avisa (riesgo de disco lleno).
          const ramBad = typeof s.ram_pct === 'number' && s.ram_pct >= 80;
          const cpuBad = typeof s.cpu_pct === 'number' && s.cpu_pct >= 80;
          const diskBad = typeof s.disk_pct === 'number' && s.disk_pct >= 90;
          const bad = ramBad || cpuBad || diskBad;
          supaResSema = { key: 'supabase_res', kind: 'usage', ok: !bad, at: s.at,
            status: bad ? 'error' : 'ok',
            max_pct: max, ram_pct: s.ram_pct, disk_pct: s.disk_pct, cpu_pct: s.cpu_pct };
        }
      }
    } catch { /* svc_supabase_res ausente */ }

    const db = await probeDb();
    // Muestra periódica del estado (la vigía cada 15 min) → uptime temporal de BD y API.
    if (logHistory) {
      supabase.from('service_status_log').insert([
        { service: 'database', ok: db.ok },
        { service: 'api', ok: true },
      ]).then(() => {}, () => {});
    }
    const arr = [
      { key: 'api', kind: 'live', ok: true, at: new Date().toISOString(), status: 'live' },
      { key: 'database', kind: 'db', ok: db.ok, at: db.at, status: db.status, latency_ms: db.latency_ms },
      cronSema('challenge_credits'),
      cronSema('referral_validations'),
      cronSema('backup'),
      purgeSema,
      svcSema('stripe'),
      svcSema('whisper'),
      svcSema('openai'),
      groqSema,
      pushSema,
      webhookSema,
      supaResSema,
    ];
    // Añade uptime 24h/7d a cada semáforo que tenga histórico.
    const uptime = await readServiceUptime();
    for (const s of arr) {
      const u = uptime[s.key];
      if (u) { s.up24 = u.up24; s.up7 = u.up7; s.samples7 = u.n7; }
    }
    return arr;
  }

  return { markService, computeSemaphores };
}
