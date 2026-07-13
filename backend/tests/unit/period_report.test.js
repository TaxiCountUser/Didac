// Test de la RPC period_report (Mes 3, M3-2): agrega el cierre de jornada en la
// BD (ingresos/gasto/por-método + ventanas de actividad por día). Verifica los
// totales, el desglose por método, la actividad y el AISLAMIENTO por tenant (RLS).
// Requiere el stack local.
import assert from 'node:assert';
import { createClient } from '@supabase/supabase-js';

process.env.NODE_ENV = 'test';
process.env.SUPABASE_URL = process.env.SUPABASE_URL || 'http://localhost:54321';
process.env.SUPABASE_SERVICE_ROLE_KEY =
  process.env.SUPABASE_SERVICE_ROLE_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UtZGVtbyIsImlhdCI6MTcwMDAwMDAwMCwiZXhwIjoyMDAwMDAwMDAwfQ.8T3kmJ5SaqY3bVmU02ZJ4MIoHe5z7R4qQ4T9VqJA8hk';
const ANON =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlLWRlbW8iLCJpYXQiOjE3MDAwMDAwMDAsImV4cCI6MjAwMDAwMDAwMH0.ZxBhVEYye2lqm5NDdkey-JP6uTHcqvZriXUoBtyQniY';

const { buildApp } = await import('../../src/server.js');
const { stackReachable, skipNoStack } = await import('./_stack.js');

let failures = 0;
const check = (name, fn) =>
  fn()
    .then(() => console.log(`✓ ${name}`))
    .catch((e) => { failures++; console.error(`✗ ${name}:`, e.message); });

function asUser(token) {
  return createClient(process.env.SUPABASE_URL, ANON, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
}

async function run() {
  const app = await buildApp();
  const sb = app.supabase;
  assert.ok(sb, 'service_role configurado (stack local arriba)');
  if (!(await stackReachable(sb))) return skipNoStack('period_report.test.js', app);

  const anon = createClient(process.env.SUPABASE_URL, ANON, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const emailA = `per.owner.${Date.now()}@test.com`;
  const suA = await anon.auth.signUp({ email: emailA, password: 'Owner12345!',
    options: { data: { company_name: 'Flota Period A' } } });
  assert.ok(!suA.error, `signUp A: ${suA.error?.message}`);
  const ownerA = suA.data.user.id;
  const tokenA = suA.data.session.access_token;
  const { data: profA } = await sb.from('users').select('tenant_id').eq('id', ownerA).single();
  const tenantA = profA.tenant_id;

  const emailB = `per.owner.${Date.now()}b@test.com`;
  const suB = await anon.auth.signUp({ email: emailB, password: 'Owner12345!',
    options: { data: { company_name: 'Flota Period B' } } });
  assert.ok(!suB.error, `signUp B: ${suB.error?.message}`);
  const ownerB = suB.data.user.id;
  const { data: profB } = await sb.from('users').select('tenant_id').eq('id', ownerB).single();
  const tenantB = profB.tenant_id;

  // Semillas: un día concreto (2026-03-10) con ingresos por método y un gasto.
  const day = '2026-03-10T';
  await sb.from('transactions').insert([
    { tenant_id: tenantA, user_id: ownerA, amount: 100.00, type: 'income',  payment_method: 'card', created_at: `${day}08:00:00Z` },
    { tenant_id: tenantA, user_id: ownerA, amount: 50.00,  type: 'income',  payment_method: 'cash', created_at: `${day}12:00:00Z` },
    { tenant_id: tenantA, user_id: ownerA, amount: 25.00,  type: 'income',  payment_method: 'card', created_at: `${day}16:00:00Z` },
    { tenant_id: tenantA, user_id: ownerA, amount: 30.00,  type: 'expense', category: 'combustible', created_at: `${day}18:00:00Z` },
    // Ruido en tenant B (no debe colarse):
    { tenant_id: tenantB, user_id: ownerB, amount: 777.00, type: 'income',  payment_method: 'card', created_at: `${day}09:00:00Z` },
  ]);

  const range = { p_from: '2026-03-01T00:00:00Z', p_to: '2026-04-01T00:00:00Z', p_offset: 0 };

  await check('period_report agrega ingresos, gasto e ingresos por método', async () => {
    const { data, error } = await asUser(tokenA).rpc('period_report', range);
    assert.ok(!error, `rpc: ${error?.message}`);
    assert.strictEqual(Number(data.income), 175);   // 100 + 50 + 25
    assert.strictEqual(Number(data.expense), 30);
    assert.strictEqual(Number(data.income_by_method.card), 125); // 100 + 25
    assert.strictEqual(Number(data.income_by_method.cash), 50);
  });

  await check('period_report devuelve la ventana de actividad del día', async () => {
    const { data } = await asUser(tokenA).rpc('period_report', range);
    assert.strictEqual(data.tx_activity.length, 1, 'un solo día con actividad');
    const [first, last] = data.tx_activity[0];
    assert.ok(new Date(first).getTime() < new Date(last).getTime(), 'first < last');
    // first = 08:00, last = 18:00 (incluye el gasto en la actividad).
    assert.strictEqual(new Date(first).toISOString(), '2026-03-10T08:00:00.000Z');
    assert.strictEqual(new Date(last).toISOString(), '2026-03-10T18:00:00.000Z');
  });

  await check('period_report NO incluye transacciones de otro tenant (RLS)', async () => {
    const { data } = await asUser(tokenA).rpc('period_report', range);
    assert.strictEqual(Number(data.income), 175, 'no debe colarse el ingreso del tenant B');
  });

  await check('period_report respeta el rango de fechas (vacío -> ceros)', async () => {
    const { data } = await asUser(tokenA).rpc('period_report', {
      p_from: '2000-01-01T00:00:00Z', p_to: '2000-02-01T00:00:00Z', p_offset: 0,
    });
    assert.strictEqual(Number(data.income), 0);
    assert.strictEqual(Number(data.expense), 0);
    assert.strictEqual(data.tx_activity.length, 0);
  });

  await sb.from('transactions').delete().eq('tenant_id', tenantA);
  await sb.from('transactions').delete().eq('tenant_id', tenantB);
  await sb.auth.admin.deleteUser(ownerA);
  await sb.auth.admin.deleteUser(ownerB);
  await app.close();

  if (failures > 0) {
    console.error(`\n${failures} test(s) de period_report fallaron.`);
    process.exit(1);
  }
  console.log('\nTests de period_report OK.');
  process.exit(0);
}

run().catch((e) => {
  console.error('Error inesperado en period_report.test.js:', e);
  process.exit(1);
});
