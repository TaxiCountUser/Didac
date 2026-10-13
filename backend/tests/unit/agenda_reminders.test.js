// Tests (sin red) de los recordatorios de la agenda (agenda_reminders.js):
// cuándo toca cada aviso, la regla de la madrugada y los textos.
//
//   Uso: node tests/unit/agenda_reminders.test.js
import assert from 'node:assert/strict';
import { madridParts, madridToUtc, dayReminderAt, dueReminders, reminderPush } from '../../src/agenda_reminders.js';
import { pushText } from '../../src/push_i18n.js';

const H = 3600000;
const at = (y, m, d, h, mi = 0) => madridToUtc(y, m, d, h, mi); // hora de España
const hm = (ms) => { const p = madridParts(ms); return `${p.d}/${p.m} ${p.h}:${String(p.mi).padStart(2, '0')}`; };

// Conversión hora España <-> UTC (verano +2, invierno +1, cambio de hora).
assert.equal(new Date(at(2026, 7, 15, 10)).toISOString(), '2026-07-15T08:00:00.000Z');
assert.equal(new Date(at(2026, 12, 15, 10)).toISOString(), '2026-12-15T09:00:00.000Z');
assert.equal(hm(at(2026, 10, 25, 12)), '25/10 12:00'); // día del cambio de hora

// "1 día antes": servicio a las 10:30 -> aviso el día anterior a las 10:30.
assert.equal(hm(dayReminderAt(at(2026, 10, 20, 10, 30))), '19/10 10:30');
// Madrugada: servicio a las 05:00 -> víspera a las 21:00 (no a las 5 de la mañana).
assert.equal(hm(dayReminderAt(at(2026, 10, 20, 5))), '19/10 21:00');
// Servicio a las 23:30 -> 24 h antes serían las 23:30 -> víspera 21:00.
assert.equal(hm(dayReminderAt(at(2026, 10, 20, 23, 30))), '19/10 21:00');
// Servicio a las 00:30 -> víspera (día 19) a las 21:00.
assert.equal(hm(dayReminderAt(at(2026, 10, 20, 0, 30))), '19/10 21:00');
// 07:00 ya no es madrugada.
assert.equal(hm(dayReminderAt(at(2026, 10, 20, 7))), '19/10 7:00');

// Qué toca en cada momento (servicio el 20/10 a las 10:30).
const svc = at(2026, 10, 20, 10, 30);
assert.deepEqual(dueReminders(svc, at(2026, 10, 19, 10, 0)), [], 'aún no');
assert.deepEqual(dueReminders(svc, at(2026, 10, 19, 10, 30)), ['day']);
assert.deepEqual(dueReminders(svc, at(2026, 10, 19, 12, 0)), ['day'], 'recupera con <=2 h de retraso');
assert.deepEqual(dueReminders(svc, at(2026, 10, 19, 13, 0)), [], 'más de 2 h tarde: ya no');
assert.deepEqual(dueReminders(svc, at(2026, 10, 20, 9, 0)), []);
assert.deepEqual(dueReminders(svc, at(2026, 10, 20, 9, 30)), ['hour']);
assert.deepEqual(dueReminders(svc, at(2026, 10, 20, 10, 15)), ['hour']);
assert.deepEqual(dueReminders(svc, at(2026, 10, 20, 10, 30)), [], 'ya empezó');
// Servicio creado con poca antelación (dentro de la última hora): solo el de 1 h.
assert.deepEqual(dueReminders(at(2026, 10, 20, 10, 30), at(2026, 10, 20, 10, 0)), ['hour']);

// Textos.
const ev = { scheduled_at: new Date(svc).toISOString(), pickup: 'Sants', destination: 'Aeropuerto', name: 'Élite' };
const tomorrow = reminderPush('day', ev, at(2026, 10, 19, 10, 30));
assert.equal(tomorrow.key, 'agenda_tomorrow');
assert.equal(pushText('es', tomorrow.key, tomorrow.args).body,
  'Recuerda: mañana a las 10:30 tienes este servicio: Sants → Aeropuerto · Élite');
// Víspera a las 21:00 de un servicio a las 00:30 -> "mañana a las 00:30".
const late = reminderPush('day', { scheduled_at: new Date(at(2026, 10, 20, 0, 30)).toISOString() }, at(2026, 10, 19, 21));
assert.equal(pushText('ca', late.key, late.args).body, 'Recorda: demà a les 00:30 tens aquest servei: —');
const hour = reminderPush('hour', ev, at(2026, 10, 20, 9, 30));
assert.equal(pushText('es', hour.key, hour.args).title, '⏰ Servicio en 1 hora');
assert.equal(pushText('en', hour.key, hour.args).body, 'At 10:30: Sants → Aeropuerto · Élite');

// --- Pasada completa con una BD falsa: destinatarios y no repetir ---
const { createAgendaReminders } = await import('../../src/agenda_reminders.js');
const NOW = at(2026, 10, 20, 9, 30);
const iso = (ms) => new Date(ms).toISOString();
const db = {
  tenants: [{ id: 'T' }],
  agenda_events: [
    { id: 'e1', tenant_id: 'T', scheduled_at: iso(at(2026, 10, 20, 10, 30)), pickup: 'A', destination: 'B', assigned_to: 'drv' }, // 1 h -> conductor
    { id: 'e2', tenant_id: 'T', scheduled_at: iso(at(2026, 10, 21, 9, 30)), name: 'X', assigned_to: null },                    // 1 día -> jefe
    { id: 'e3', tenant_id: 'T', scheduled_at: iso(at(2026, 10, 20, 15, 0)), assigned_to: null },                               // nada ahora
  ],
  users: [
    { id: 'boss', tenant_id: 'T', role: 'owner', active: true },
    { id: 'drv', tenant_id: 'T', role: 'driver', active: true },
  ],
};
const sentKeys = new Set();
const fake = {
  from(table) {
    const f = {};
    const b = {
      select: () => b, is: () => b, gt: () => b, lte: () => b,
      eq: (k, v) => { f[k] = v; return b; }, in: (k, v) => { f[k] = v; return b; },
      upsert: (row) => { f.upsert = row; return b; },
      maybeSingle: async () => ({ data: db.users.find((u) => u.id === f.id) ?? null }),
      then: (res, rej) => Promise.resolve((() => {
        if (table === 'agenda_reminders_sent') {
          const k = `${f.upsert.event_id}|${f.upsert.kind}|${f.upsert.ref}`;
          if (sentKeys.has(k)) return { data: [] };
          sentKeys.add(k); return { data: [{ event_id: f.upsert.event_id }] };
        }
        if (table === 'users') return { data: db.users.filter((u) => u.role === f.role) };
        return { data: db[table] };
      })()).then(res, rej),
    };
    return b;
  },
};
const pushes = [];
const rem = createAgendaReminders({ supabase: fake, notifyUsers: async (to, key, args) => pushes.push({ to, key, args }) });
const r1 = await rem.run({ now: NOW });
assert.equal(r1.sent, 2);
assert.deepEqual(pushes.map((p) => `${p.to.join(',')}:${p.key}`).sort(), ['boss:agenda_tomorrow', 'drv:agenda_hour']);
const r2 = await rem.run({ now: NOW + 60000 });
assert.equal(r2.sent, 0, 'no repite');

console.log('agenda_reminders: OK');
