// Tests de integración del reparto trimestral de flota (Loop #4) con un cliente
// Supabase MOCK en memoria (sin red). Valida el cálculo de métricas, las reglas
// de negocio RN-05/06/13/21, la extensión de suscripción, la notificación al
// JEFE, el log de auditoría, el modo dryRun y la idempotencia.
import assert from 'node:assert';
import {
  computeTenantQuarterMetrics, runQuarterlyFleetRewards, quarterOf, quarterRange,
} from '../../src/gamification.js';

// ── Mock de Supabase: query builder "thenable" sobre tablas en memoria ────────
class Query {
  constructor(db, table) {
    this.db = db; this.table = table; this.filters = [];
    this.op = 'select'; this.payload = null; this.single = false; this.conflict = null;
  }
  select() { return this; }
  insert(p) { this.op = 'insert'; this.payload = p; return this; }
  update(p) { this.op = 'update'; this.payload = p; return this; }
  upsert(p, opts) { this.op = 'upsert'; this.payload = p; this.conflict = opts?.onConflict; return this; }
  eq(c, v) { this.filters.push(['eq', c, v]); return this; }
  neq(c, v) { this.filters.push(['neq', c, v]); return this; }
  gte(c, v) { this.filters.push(['gte', c, v]); return this; }
  lt(c, v) { this.filters.push(['lt', c, v]); return this; }
  order() { return this; }
  range() { return this; }
  maybeSingle() { this.single = true; return this; }
  _match(row) {
    return this.filters.every(([op, c, v]) => {
      const x = row[c];
      if (op === 'eq') return x === v;
      if (op === 'neq') return x !== v;
      if (op === 'gte') return x >= v;
      if (op === 'lt') return x < v;
      return true;
    });
  }
  _run() {
    const t = (this.db[this.table] ||= []);
    if (this.op === 'select') {
      const rows = t.filter((r) => this._match(r));
      return this.single ? { data: rows[0] ?? null, error: null } : { data: rows, error: null };
    }
    if (this.op === 'insert') {
      const arr = Array.isArray(this.payload) ? this.payload : [this.payload];
      const inserted = arr.map((p) => ({ id: p.id ?? `id_${t.length + 1}_${Math.random().toString(36).slice(2, 6)}`, ...p }));
      t.push(...inserted);
      return this.single ? { data: inserted[0], error: null } : { data: inserted, error: null };
    }
    if (this.op === 'update') {
      let n = 0;
      for (const r of t) { if (this._match(r)) { Object.assign(r, this.payload); n++; } }
      return { data: null, error: null, count: n };
    }
    if (this.op === 'upsert') {
      const keys = (this.conflict || '').split(',').map((s) => s.trim()).filter(Boolean);
      const arr = Array.isArray(this.payload) ? this.payload : [this.payload];
      for (const p of arr) {
        const found = keys.length ? t.find((r) => keys.every((k) => r[k] === p[k])) : null;
        if (found) Object.assign(found, p);
        else t.push({ id: `id_${t.length + 1}`, ...p });
      }
      return { data: null, error: null };
    }
    return { data: null, error: null };
  }
  then(resolve, reject) { try { resolve(this._run()); } catch (e) { reject(e); } }
}
const makeSupabase = (db) => ({ from: (table) => new Query(db, table) });
const silent = { info() {}, warn() {}, error() {} };

// ── Fechas de referencia (relativas al trimestre en curso) ────────────────────
const { year, quarter } = quarterOf();
const range = quarterRange(year, quarter);
const now = new Date().toISOString();
const beforeQuarter = new Date(Date.parse(range.startISO) - 5 * 86400000).toISOString();
const old60 = new Date(Date.now() - 60 * 86400000).toISOString();
const since30ISO = new Date(Date.now() - 30 * 86400000).toISOString();

// Construye un dataset base: 10 conductores activos, 5 con logro este trimestre.
function baseDb() {
  const db = { users: [], odometer_readings: [], challenge_claims: [], tenants: [], fleet_quarterly_metrics: [], cron_execution_logs: [] };
  db.tenants.push({ id: 'T1', name: 'Flota Uno', trial_ends_at: new Date(Date.now() + 10 * 86400000).toISOString() });
  db.users.push({ id: 'O1', tenant_id: 'T1', role: 'owner', active: true });
  for (let i = 1; i <= 10; i++) {
    db.users.push({ id: `D${i}`, tenant_id: 'T1', role: 'driver', active: true });
    db.odometer_readings.push({ user_id: `D${i}`, tenant_id: 'T1', taken_at: now }); // activo
  }
  // 5 conductores (D1..D5) con un logro dentro del trimestre.
  for (let i = 1; i <= 5; i++) {
    db.challenge_claims.push({ user_id: `D${i}`, tenant_id: 'T1', status: 'rewarded', created_at: now });
  }
  return db;
}

// ── Test 1: cálculo de métricas + reglas de negocio ───────────────────────────
async function testMetrics() {
  const db = baseDb();
  // RN-05: D1 con un segundo claim -> sigue contando 1 vez.
  db.challenge_claims.push({ user_id: 'D1', tenant_id: 'T1', status: 'rewarded', created_at: now });
  // RN-21: D6 logró un reto ANTES del trimestre -> no cuenta.
  db.challenge_claims.push({ user_id: 'D6', tenant_id: 'T1', status: 'rewarded', created_at: beforeQuarter });
  // Fraude: D7 con claim rechazado este trimestre -> no cuenta.
  db.challenge_claims.push({ user_id: 'D7', tenant_id: 'T1', status: 'rejected', created_at: now });
  // RN-06: D11 inactivo (lectura hace 60 días) con logro -> no cuenta ni en activos ni en logros.
  db.users.push({ id: 'D11', tenant_id: 'T1', role: 'driver', active: true });
  db.odometer_readings.push({ user_id: 'D11', tenant_id: 'T1', taken_at: old60 });
  db.challenge_claims.push({ user_id: 'D11', tenant_id: 'T1', status: 'rewarded', created_at: now });
  // Conductor inactivo en BD (active=false) -> fuera del denominador.
  db.users.push({ id: 'D12', tenant_id: 'T1', role: 'driver', active: false });
  db.odometer_readings.push({ user_id: 'D12', tenant_id: 'T1', taken_at: now });

  const m = await computeTenantQuarterMetrics(makeSupabase(db), 'T1', range, since30ISO);
  assert.equal(m.active_drivers, 10, 'active_drivers = 10 (D1..D10; D11 inactivo, D12 active=false)');
  assert.equal(m.drivers_with_achievement, 5, 'achievement = 5 (D1..D5; RN-05 cuenta D1 una vez; D6 fuera de trimestre; D7 rechazado; D11 inactivo)');
  assert.equal(m.completion_rate, 50, 'completion_rate = 50%');
  console.log('  ✓ métricas + RN-05/06/21 + fraude');
}

// ── Test 2: reparto real (DoD: 50% -> 7 días) ─────────────────────────────────
async function testRewardFlow() {
  const db = baseDb();
  const tenantBefore = db.tenants[0].trial_ends_at;
  const notifications = [];
  const notifyOwner = async (userId, title, body) => { notifications.push({ userId, title, body }); };

  const summary = await runQuarterlyFleetRewards(makeSupabase(db), {
    year, quarter, notifyOwner, log: silent,
  });

  assert.equal(summary.tenants_processed, 1, '1 tenant procesado');
  assert.equal(summary.rewards_granted, 1, '1 recompensa concedida');

  const row = db.fleet_quarterly_metrics.find((r) => r.tenant_id === 'T1');
  assert.ok(row, 'fila de métricas creada');
  assert.equal(row.active_drivers, 10);
  assert.equal(row.drivers_with_achievement, 5);
  assert.equal(row.completion_rate, 50);
  assert.equal(row.reward_days_awarded, 7, 'DoD: 50% -> 7 días');

  // Suscripción extendida ~7 días.
  const after = Date.parse(db.tenants[0].trial_ends_at);
  const expected = Date.parse(tenantBefore) + 7 * 86400000;
  assert.ok(Math.abs(after - expected) < 60000, 'trial_ends_at +7 días');

  // Notificación al JEFE (owner O1).
  assert.equal(notifications.length, 1, '1 notificación al JEFE');
  assert.equal(notifications[0].userId, 'O1', 'notifica al owner O1');

  // Log de auditoría success.
  const logRow = db.cron_execution_logs.find((r) => r.status === 'success');
  assert.ok(logRow, 'log de cron en success');
  assert.equal(logRow.rewards_granted, 1);
  assert.equal(logRow.tenants_processed, 1);
  console.log('  ✓ reparto real (50%→7d), extensión, push al JEFE y log');
}

// ── Test 3: dryRun no premia ni notifica ──────────────────────────────────────
async function testDryRun() {
  const db = baseDb();
  const tenantBefore = db.tenants[0].trial_ends_at;
  const notifications = [];
  await runQuarterlyFleetRewards(makeSupabase(db), {
    year, quarter, dryRun: true, notifyOwner: async (...a) => notifications.push(a), log: silent,
  });
  const row = db.fleet_quarterly_metrics.find((r) => r.tenant_id === 'T1');
  assert.equal(row.completion_rate, 50, 'dryRun calcula la tasa igualmente');
  assert.equal(row.reward_days_awarded, 0, 'dryRun no concede días');
  assert.equal(db.tenants[0].trial_ends_at, tenantBefore, 'dryRun no extiende suscripción');
  assert.equal(notifications.length, 0, 'dryRun no notifica');
  console.log('  ✓ dryRun (calcula sin premiar ni notificar)');
}

// ── Test 4: idempotencia (ejecutar dos veces no duplica filas) ────────────────
async function testIdempotency() {
  const db = baseDb();
  const sb = makeSupabase(db);
  await runQuarterlyFleetRewards(sb, { year, quarter, notifyOwner: async () => {}, log: silent });
  await runQuarterlyFleetRewards(sb, { year, quarter, notifyOwner: async () => {}, log: silent });
  const rows = db.fleet_quarterly_metrics.filter((r) => r.tenant_id === 'T1');
  assert.equal(rows.length, 1, 'upsert idempotente: una sola fila por tenant+año+trimestre');
  console.log('  ✓ idempotencia (upsert único por trimestre)');
}

await testMetrics();
await testRewardFlow();
await testDryRun();
await testIdempotency();
console.log('fleet_rewards.test.js OK');
