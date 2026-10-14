// Tests (sin red) de los correos de bienvenida / fin de prueba (trial_emails.js):
// plantillas en los 3 idiomas y a quién se envía cada aviso (una sola vez).
//
//   Uso: node tests/unit/trial_emails.test.js
import assert from 'node:assert/strict';
import { renderTrialEmail, createTrialEmails } from '../../src/trial_emails.js';

const DAY = 86400000;
const NOW = new Date('2026-10-20T08:00:00Z');
const iso = (ms) => new Date(ms).toISOString();

// --- Plantillas ---
for (const loc of ['es', 'ca', 'en', 'xx']) {
  for (const kind of ['welcome', 'trial_ending', 'trial_ended']) {
    const m = renderTrialEmail(kind, loc, { trialEndsAt: iso(Date.now() + 2 * DAY), webUrl: 'https://www.taxicount.com' });
    assert.ok(m.subject && m.html && m.text, `${loc}/${kind} vacío`);
    assert.ok(!/\{\w+\}/.test(m.subject + m.html + m.text), `${loc}/${kind} con placeholder sin rellenar`);
    assert.ok(m.html.includes('https://www.taxicount.com'), `${loc}/${kind} sin enlace a la web`);
  }
}
assert.match(renderTrialEmail('trial_ending', 'es', { trialEndsAt: '2026-10-22T10:00:00Z', webUrl: 'x' }).subject, /22\/10\/2026/);
assert.equal(renderTrialEmail('welcome', 'xx', { webUrl: 'x' }).subject, renderTrialEmail('welcome', 'es', { webUrl: 'x' }).subject, 'idioma desconocido -> es');

// --- Lógica de envío con un supabase falso ---
function fakeSupabase({ tenants, owners, providers }) {
  const sentLog = new Set();
  const q = (table) => {
    const st = { table, filters: {} };
    const b = {
      select: () => b, is: () => b, or: () => b, not: () => b, order: () => b, limit: () => b,
      eq: (k, v) => { st.filters[k] = v; return b; },
      upsert: (row) => { st.upsert = row; return b; },
      delete: () => { st.del = true; return b; },
      maybeSingle: async () => ({ data: owners[st.filters.tenant_id] ?? null }),
      then: (res, rej) => Promise.resolve((() => {
        if (table === 'tenants') return { data: tenants };
        if (table === 'device_tokens') return { data: [] };
        if (table === 'trial_emails_sent' && st.upsert) {
          const k = `${st.upsert.tenant_id}|${st.upsert.kind}|${st.upsert.ref}`;
          if (sentLog.has(k)) return { data: [] };
          sentLog.add(k); return { data: [{ tenant_id: st.upsert.tenant_id }] };
        }
        return { data: [] };
      })()).then(res, rej),
    };
    return b;
  };
  return {
    from: q,
    auth: { admin: { getUserById: async (id) => ({ data: { user: { app_metadata: { providers: providers[id] ?? ['email'] } } } }) } },
  };
}

const tenants = [
  // nuevo con Google, prueba hasta dentro de 15 días -> solo bienvenida
  { id: 't1', created_at: iso(NOW - DAY), trial_ends_at: iso(+NOW + 14 * DAY), subscription_status: 'trialing' },
  // nuevo con email -> también bienvenida (desde la mig. 096 todos eligen empresa/autónomo)
  { id: 't2', created_at: iso(NOW - DAY), trial_ends_at: iso(+NOW + 14 * DAY), subscription_status: 'trialing' },
  // le quedan 2 días -> trial_ending
  { id: 't3', created_at: iso(NOW - 13 * DAY), trial_ends_at: iso(+NOW + 2 * DAY), subscription_status: 'trialing' },
  // acabó ayer -> trial_ended
  { id: 't4', created_at: iso(NOW - 16 * DAY), trial_ends_at: iso(NOW - DAY), subscription_status: 'trialing' },
  // le quedan 2 días pero YA PAGA -> nada
  { id: 't5', created_at: iso(NOW - 13 * DAY), trial_ends_at: iso(+NOW + 2 * DAY), subscription_status: 'active' },
  // acabó hace 10 días -> nada (no se escribe a los antiguos)
  { id: 't6', created_at: iso(NOW - 25 * DAY), trial_ends_at: iso(NOW - 10 * DAY), subscription_status: 'trialing' },
  // owner borrado -> nada
  { id: 't7', created_at: iso(NOW - 13 * DAY), trial_ends_at: iso(+NOW + 2 * DAY), subscription_status: 'trialing' },
];
const owners = Object.fromEntries(tenants.map((t) => [t.id, { id: `u_${t.id}`, email: `${t.id}@x.com`, active: true }]));
owners.t7.deleted_at = iso(NOW);
const supabase = fakeSupabase({ tenants, owners, providers: { u_t1: ['google'] } });

const calls = [];
const fetchImpl = async (url, opts) => { calls.push(JSON.parse(opts.body)); return { ok: true, text: async () => '' }; };

// Sin clave de Resend: no envía nada.
const off = createTrialEmails({ supabase, env: {}, fetchImpl });
assert.deepEqual(await off.run({ now: NOW }), { email: false, sent: 0 });
assert.equal(calls.length, 0);

const te = createTrialEmails({ supabase, env: { RESEND_API_KEY: 're_test' }, fetchImpl });
const r1 = await te.run({ now: NOW });
const got = r1.details.map((d) => `${d.tenant}:${d.kind}`).sort();
assert.deepEqual(got, ['t1:welcome', 't2:welcome', 't3:trial_ending', 't4:trial_ended']);
assert.deepEqual(calls.map((c) => c.to[0]).sort(), ['t1@x.com', 't2@x.com', 't3@x.com', 't4@x.com']);

// Segunda pasada el mismo día: no repite.
const r2 = await te.run({ now: NOW });
assert.equal(r2.sent, 0, 'no debe repetir avisos ya enviados');

// Modo prueba: 3 correos a la dirección indicada.
calls.length = 0;
assert.deepEqual(await te.sendTest('yo@x.com', 'ca'), { email: true, sent: 3 });
assert.ok(calls.every((c) => c.to[0] === 'yo@x.com'));

console.log('trial_emails: OK');
