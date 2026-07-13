// Test de los rollups diarios (Mes 3, M3-3/M3-4): verifica que las RPCs de
// rollup devuelven LO MISMO que las crudas (garantía de exactitud), que el
// trigger mantiene los buckets en insert/update/delete, y el aislamiento por
// tenant (RLS). Requiere el stack local.
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
const RANGE = { p_from: '2026-01-01T00:00:00Z', p_to: '2027-01-01T00:00:00Z' };

async function run() {
  const app = await buildApp();
  const sb = app.supabase;
  assert.ok(sb, 'service_role configurado (stack local arriba)');
  if (!(await stackReachable(sb))) return skipNoStack('rollups.test.js', app);

  const anon = createClient(process.env.SUPABASE_URL, ANON, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const suA = await anon.auth.signUp({ email: `roll.a.${Date.now()}@test.com`, password: 'Owner12345!',
    options: { data: { company_name: 'Rollup A' } } });
  assert.ok(!suA.error, `signUp A: ${suA.error?.message}`);
  const ownerA = suA.data.user.id; const tokenA = suA.data.session.access_token;
  const { data: profA } = await sb.from('users').select('tenant_id').eq('id', ownerA).single();
  const tenantA = profA.tenant_id;

  const suB = await anon.auth.signUp({ email: `roll.b.${Date.now()}@test.com`, password: 'Owner12345!',
    options: { data: { company_name: 'Rollup B' } } });
  const ownerB = suB.data.user.id;
  const { data: profB } = await sb.from('users').select('tenant_id').eq('id', ownerB).single();
  const tenantB = profB.tenant_id;

  // Semilla (el trigger puebla los rollups al insertar; created_at a mediodía UTC
  // para que el día Madrid == día UTC).
  await sb.from('transactions').insert([
    { tenant_id: tenantA, user_id: ownerA, amount: 100, type: 'income',  payment_method: 'card', created_at: '2026-03-10T13:00:00Z' },
    { tenant_id: tenantA, user_id: ownerA, amount: 40,  type: 'income',  payment_method: 'cash', created_at: '2026-03-10T15:00:00Z' },
    { tenant_id: tenantA, user_id: ownerA, amount: 25,  type: 'expense', category: 'combustible', created_at: '2026-03-10T16:00:00Z' },
    { tenant_id: tenantA, user_id: ownerA, amount: 200, type: 'income',  payment_method: 'card', created_at: '2026-05-20T13:00:00Z' },
    { tenant_id: tenantA, user_id: ownerA, amount: 10,  type: 'expense', category: 'peaje',       created_at: '2026-05-20T14:00:00Z' },
    { tenant_id: tenantB, user_id: ownerB, amount: 999, type: 'income',  payment_method: 'card', created_at: '2026-03-10T13:00:00Z' },
  ]);

  await check('el trigger pobló los rollups del tenant A', async () => {
    const { data } = await sb.from('tenant_daily_rollup').select('day, income, expense')
      .eq('tenant_id', tenantA).order('day');
    assert.strictEqual(data.length, 2, 'dos días con actividad');
    const d310 = data.find((r) => r.day === '2026-03-10');
    assert.strictEqual(Number(d310.income), 140);
    assert.strictEqual(Number(d310.expense), 25);
  });

  await check('report_summary_rollup == report_summary (exactitud)', async () => {
    const u = asUser(tokenA);
    const { data: roll } = await u.rpc('report_summary_rollup', RANGE);
    const { data: raw }  = await u.rpc('report_summary', RANGE);
    assert.strictEqual(Number(roll.income),  Number(raw.income));
    assert.strictEqual(Number(roll.expense), Number(raw.expense));
    assert.strictEqual(Number(roll.income), 340);
    assert.deepStrictEqual(roll.expense_by_category, raw.expense_by_category);
    assert.strictEqual(Number(roll.expense_by_category.combustible), 25);
    assert.strictEqual(Number(roll.expense_by_category.peaje), 10);
  });

  await check('period_report_rollup == period_report (dinero y método)', async () => {
    const u = asUser(tokenA);
    const { data: roll } = await u.rpc('period_report_rollup', RANGE);
    const { data: raw }  = await u.rpc('period_report', { ...RANGE, p_offset: 0 });
    assert.strictEqual(Number(roll.income),  Number(raw.income));
    assert.strictEqual(Number(roll.expense), Number(raw.expense));
    assert.deepStrictEqual(roll.income_by_method, raw.income_by_method);
    assert.strictEqual(Number(roll.income_by_method.card), 300);
    assert.strictEqual(roll.tx_activity.length, 2, 'dos días con actividad');
  });

  await check('rollups NO cruzan tenants (RLS)', async () => {
    const { data: roll } = await asUser(tokenA).rpc('report_summary_rollup', RANGE);
    assert.strictEqual(Number(roll.income), 340, 'no debe colarse el ingreso del tenant B');
  });

  await check('el trigger mantiene el rollup en UPDATE y DELETE', async () => {
    // Sube un ingreso de 100 -> 130 en el día 10/03.
    const { data: tx } = await sb.from('transactions')
      .select('id').eq('tenant_id', tenantA).eq('amount', 100).eq('type', 'income').single();
    await sb.from('transactions').update({ amount: 130 }).eq('id', tx.id);
    let { data: roll } = await asUser(tokenA).rpc('report_summary_rollup', RANGE);
    assert.strictEqual(Number(roll.income), 370, 'update refleja +30');
    // Borra la lectura de peaje (gasto 10) del 20/05.
    const { data: tp } = await sb.from('transactions')
      .select('id').eq('tenant_id', tenantA).eq('amount', 10).eq('type', 'expense').single();
    await sb.from('transactions').delete().eq('id', tp.id);
    ({ data: roll } = await asUser(tokenA).rpc('report_summary_rollup', RANGE));
    assert.strictEqual(Number(roll.expense), 25, 'delete refleja -10');
    assert.strictEqual(roll.expense_by_category.peaje, undefined, 'peaje desaparece del desglose');
  });

  await check('borrar todas las tx de un día elimina su bucket', async () => {
    await sb.from('transactions').delete()
      .eq('tenant_id', tenantA).gte('created_at', '2026-05-01').lt('created_at', '2026-06-01');
    const { data } = await sb.from('tenant_daily_rollup').select('day').eq('tenant_id', tenantA);
    assert.ok(!data.some((r) => r.day === '2026-05-20'), 'el bucket vacío se borra');
  });

  await sb.from('transactions').delete().eq('tenant_id', tenantA);
  await sb.from('transactions').delete().eq('tenant_id', tenantB);
  await sb.auth.admin.deleteUser(ownerA);
  await sb.auth.admin.deleteUser(ownerB);
  await app.close();

  if (failures > 0) {
    console.error(`\n${failures} test(s) de rollups fallaron.`);
    process.exit(1);
  }
  console.log('\nTests de rollups OK.');
  process.exit(0);
}

run().catch((e) => { console.error('Error inesperado en rollups.test.js:', e); process.exit(1); });
