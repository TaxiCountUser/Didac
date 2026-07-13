// Test de la RPC report_summary (Mes 3, M3-1): agrega el resumen del dashboard
// en la BD. Verifica los totales, el gasto por categoría y —crítico— el
// AISLAMIENTO por tenant/rol vía RLS (INVOKER). Requiere el stack local.
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

// Cliente autenticado como un usuario concreto (RLS aplica su JWT).
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
  if (!(await stackReachable(sb))) return skipNoStack('report_summary.test.js', app);

  const anon = createClient(process.env.SUPABASE_URL, ANON, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // --- Tenant A: owner con transacciones conocidas ---
  const emailA = `rep.owner.${Date.now()}@test.com`;
  const suA = await anon.auth.signUp({ email: emailA, password: 'Owner12345!',
    options: { data: { company_name: 'Flota Report A' } } });
  assert.ok(!suA.error, `signUp A: ${suA.error?.message}`);
  const ownerA = suA.data.user.id;
  const tokenA = suA.data.session.access_token;
  const { data: profA } = await sb.from('users').select('tenant_id').eq('id', ownerA).single();
  const tenantA = profA.tenant_id;

  // --- Tenant B: otro owner con transacciones que NO deben colarse ---
  const emailB = `rep.owner.${Date.now()}b@test.com`;
  const suB = await anon.auth.signUp({ email: emailB, password: 'Owner12345!',
    options: { data: { company_name: 'Flota Report B' } } });
  assert.ok(!suB.error, `signUp B: ${suB.error?.message}`);
  const ownerB = suB.data.user.id;
  const { data: profB } = await sb.from('users').select('tenant_id').eq('id', ownerB).single();
  const tenantB = profB.tenant_id;

  // Semillas (service_role salta RLS para insertar).
  await sb.from('transactions').insert([
    { tenant_id: tenantA, user_id: ownerA, amount: 100.00, type: 'income',  payment_method: 'card' },
    { tenant_id: tenantA, user_id: ownerA, amount: 50.50,  type: 'income',  payment_method: 'cash' },
    { tenant_id: tenantA, user_id: ownerA, amount: 20.00,  type: 'expense', category: 'combustible' },
    { tenant_id: tenantA, user_id: ownerA, amount: 5.00,   type: 'expense', category: 'combustible' },
    { tenant_id: tenantA, user_id: ownerA, amount: 10.00,  type: 'expense', category: 'peaje' },
    // Ruido en el tenant B (no debe sumar en el resumen de A):
    { tenant_id: tenantB, user_id: ownerB, amount: 999.00, type: 'income',  payment_method: 'card' },
  ]);

  await check('report_summary agrega ingresos, gasto y gasto por categoría', async () => {
    const { data, error } = await asUser(tokenA).rpc('report_summary', {});
    assert.ok(!error, `rpc: ${error?.message}`);
    assert.strictEqual(Number(data.income), 150.5);
    assert.strictEqual(Number(data.expense), 35);
    assert.strictEqual(Number(data.expense_by_category.combustible), 25);
    assert.strictEqual(Number(data.expense_by_category.peaje), 10);
  });

  await check('report_summary NO incluye transacciones de otro tenant (RLS)', async () => {
    const { data } = await asUser(tokenA).rpc('report_summary', {});
    // 999 del tenant B no debe aparecer: ingresos de A = 150,5 exactos.
    assert.strictEqual(Number(data.income), 150.5, 'no debe colarse el ingreso del tenant B');
  });

  await check('report_summary respeta el filtro de rango de fechas', async () => {
    // Rango en el pasado sin transacciones -> todo a cero.
    const { data } = await asUser(tokenA).rpc('report_summary', {
      p_from: '2000-01-01T00:00:00Z', p_to: '2000-01-02T00:00:00Z',
    });
    assert.strictEqual(Number(data.income), 0);
    assert.strictEqual(Number(data.expense), 0);
  });

  // Limpieza
  await sb.from('transactions').delete().eq('tenant_id', tenantA);
  await sb.from('transactions').delete().eq('tenant_id', tenantB);
  await sb.auth.admin.deleteUser(ownerA);
  await sb.auth.admin.deleteUser(ownerB);
  await app.close();

  if (failures > 0) {
    console.error(`\n${failures} test(s) de report_summary fallaron.`);
    process.exit(1);
  }
  console.log('\nTests de report_summary OK.');
  process.exit(0);
}

run().catch((e) => {
  console.error('Error inesperado en report_summary.test.js:', e);
  process.exit(1);
});
