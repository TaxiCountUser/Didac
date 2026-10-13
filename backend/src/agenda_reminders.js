// Recordatorios push de la AGENDA (servicios programados).
//
// Dos avisos por servicio pendiente:
//   day  -> 24 h antes. Si eso cae de madrugada (23:00–07:00, hora de España), se
//           adelanta a la VÍSPERA a las 21:00 para no despertar a nadie.
//   hour -> 1 hora antes.
// Destinatario: el conductor ASIGNADO (agenda_events.assigned_to, mig. 088); si no
// hay, el/los owner(s) de la empresa (jefe, o el propio autónomo) para que lo asigne.
// Solo empresas con la agenda activada y servicios 'pending'. Cada aviso UNA vez
// (agenda_reminders_sent, mig. 090; `ref` = scheduled_at, así un servicio que se
// cambia de hora vuelve a avisar). Si el servidor estuvo caído, se recupera un
// aviso con hasta 2 h de retraso; más tarde ya no (no tiene sentido).
//
// El servidor está siempre encendido (Render starter): un intervalo de 60 s dentro
// del proceso lo ejecuta. Además hay un endpoint de cron para lanzarlo a mano.

const MIN = 60000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const CATCH_UP = 2 * HOUR; // retraso máximo con el que aún se envía un aviso
const TZ = 'Europe/Madrid';

const partsFmt = new Intl.DateTimeFormat('en-GB', {
  timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit',
  hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
});
/** Fecha/hora en España de un instante: {y, m, d, h, mi}. */
export function madridParts(ms) {
  const p = Object.fromEntries(partsFmt.formatToParts(new Date(ms)).map((x) => [x.type, x.value]));
  return { y: +p.year, m: +p.month, d: +p.day, h: +p.hour, mi: +p.minute };
}
/** Instante UTC de una fecha/hora local de España (maneja el cambio de hora). */
export function madridToUtc(y, m, d, h, mi = 0) {
  let guess = Date.UTC(y, m - 1, d, h, mi);
  for (let i = 0; i < 2; i++) {
    const p = madridParts(guess);
    const asUtc = Date.UTC(p.y, p.m - 1, p.d, p.h, p.mi);
    guess += Date.UTC(y, m - 1, d, h, mi) - asUtc;
  }
  return guess;
}

/** Momento en que toca el aviso de "1 día antes" (con la regla de la madrugada). */
export function dayReminderAt(serviceMs) {
  const target = serviceMs - DAY;
  const { h } = madridParts(target);
  if (h >= 23 || h < 7) {
    const s = madridParts(serviceMs);
    // Víspera (día anterior al del servicio) a las 21:00 de España.
    const prev = new Date(Date.UTC(s.y, s.m - 1, s.d - 1));
    return madridToUtc(prev.getUTCFullYear(), prev.getUTCMonth() + 1, prev.getUTCDate(), 21, 0);
  }
  return target;
}

/** Avisos que tocan AHORA para un servicio: subconjunto de ['day', 'hour']. */
export function dueReminders(serviceMs, nowMs) {
  if (serviceMs <= nowMs) return [];
  const out = [];
  const hourAt = serviceMs - HOUR;
  if (nowMs >= hourAt) return ['hour']; // dentro de la última hora: solo el de 1 h
  const dayAt = dayReminderAt(serviceMs);
  if (nowMs >= dayAt && nowMs - dayAt <= CATCH_UP) out.push('day');
  return out;
}

/** Clave de push_i18n + args para un aviso. */
export function reminderPush(kind, ev, nowMs) {
  const s = madridParts(new Date(ev.scheduled_at).getTime());
  const n = madridParts(nowMs);
  const time = `${String(s.h).padStart(2, '0')}:${String(s.mi).padStart(2, '0')}`;
  const route = [ev.pickup, ev.destination].filter(Boolean).join(' → ');
  const detail = [route, ev.name].filter(Boolean).join(' · ') || '—';
  if (kind === 'hour') return { key: 'agenda_hour', args: { time, detail } };
  const sameDay = s.y === n.y && s.m === n.m && s.d === n.d;
  return { key: sameDay ? 'agenda_today' : 'agenda_tomorrow', args: { time, detail } };
}

export function createAgendaReminders({ supabase, notifyUsers, log }) {
  let running = false;

  async function claim(eventId, kind, ref) {
    const { data, error } = await supabase.from('agenda_reminders_sent')
      .upsert({ event_id: eventId, kind, ref }, { onConflict: 'event_id,kind,ref', ignoreDuplicates: true })
      .select('event_id');
    if (error) throw error;
    return !!(data && data.length);
  }

  async function recipients(ev, ownersByTenant) {
    if (ev.assigned_to) {
      const { data: u } = await supabase.from('users').select('id, active, deleted_at')
        .eq('id', ev.assigned_to).maybeSingle();
      if (u && u.active !== false && !u.deleted_at) return [u.id];
    }
    return ownersByTenant.get(ev.tenant_id) ?? [];
  }

  /** Una pasada. Devuelve {sent, checked}. */
  async function run({ now = Date.now() } = {}) {
    if (running) return { skipped: true };
    running = true;
    try {
      const { data: tenants } = await supabase.from('tenants').select('id')
        .eq('agenda_enabled', true).is('closed_at', null);
      const tenantIds = (tenants ?? []).map((t) => t.id);
      if (!tenantIds.length) return { sent: 0, checked: 0 };
      const { data: events, error } = await supabase.from('agenda_events')
        .select('id, tenant_id, scheduled_at, name, pickup, destination, assigned_to')
        .in('tenant_id', tenantIds).eq('status', 'pending')
        .gt('scheduled_at', new Date(now).toISOString())
        .lte('scheduled_at', new Date(now + DAY + 2 * HOUR).toISOString());
      if (error) throw error;
      const due = (events ?? []).map((ev) => [ev, dueReminders(new Date(ev.scheduled_at).getTime(), now)])
        .filter(([, kinds]) => kinds.length);
      if (!due.length) return { sent: 0, checked: events?.length ?? 0 };
      const { data: owners } = await supabase.from('users').select('id, tenant_id, active, deleted_at')
        .in('tenant_id', [...new Set(due.map(([ev]) => ev.tenant_id))]).eq('role', 'owner');
      const ownersByTenant = new Map();
      for (const o of owners ?? []) {
        if (o.active === false || o.deleted_at) continue;
        ownersByTenant.set(o.tenant_id, [...(ownersByTenant.get(o.tenant_id) ?? []), o.id]);
      }
      let sent = 0;
      for (const [ev, kinds] of due) {
        for (const kind of kinds) {
          try {
            if (!(await claim(ev.id, kind, String(ev.scheduled_at)))) continue;
            const to = await recipients(ev, ownersByTenant);
            if (!to.length) continue;
            const { key, args } = reminderPush(kind, ev, now);
            await notifyUsers(to, key, args, { type: 'agenda', eventId: ev.id });
            sent++;
          } catch (e) {
            log?.warn?.(`[agenda-reminders] ${ev.id} ${kind}: ${e.message}`);
          }
        }
      }
      return { sent, checked: events.length };
    } finally {
      running = false;
    }
  }

  return { run };
}

/**
 * Arranca el intervalo (cada 60 s) y registra el endpoint de cron para lanzarlo a
 * mano. Desactivable con AGENDA_REMINDERS=off (y no corre en tests: NODE_ENV=test).
 */
export function registerAgendaReminders(app, { agendaReminders, cronOrAdmin, markCronRun, env = process.env }) {
  app.post('/api/v1/admin/cron/agenda-reminders', async (request, reply) => {
    const g = await cronOrAdmin(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const res = await agendaReminders.run();
    await markCronRun('agenda_reminders');
    return reply.send({ ok: true, ...res });
  });
  if (env.AGENDA_REMINDERS === 'off' || env.NODE_ENV === 'test') return;
  const timer = setInterval(() => {
    agendaReminders.run().catch((e) => app.log.warn(`[agenda-reminders] ${e.message}`));
  }, MIN);
  timer.unref?.();
  app.addHook('onClose', async () => clearInterval(timer));
}
