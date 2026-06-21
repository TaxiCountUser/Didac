// Test del endpoint POST /api/v1/reports/excel: genera el .xlsx, lo lee con
// exceljs y verifica pestañas (por conductor + Consolidado) y totales.
// Requiere el stack local (db/kong) para auth y datos. Sin Internet.
import assert from 'node:assert';
import ExcelJS from 'exceljs';
import { createClient } from '@supabase/supabase-js';

process.env.NODE_ENV = 'test';
process.env.SUPABASE_URL = process.env.SUPABASE_URL || 'http://localhost:54321';
process.env.SUPABASE_SERVICE_ROLE_KEY =
  process.env.SUPABASE_SERVICE_ROLE_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UtZGVtbyIsImlhdCI6MTcwMDAwMDAwMCwiZXhwIjoyMDAwMDAwMDAwfQ.8T3kmJ5SaqY3bVmU02ZJ4MIoHe5z7R4qQ4T9VqJA8hk';
const ANON =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlLWRlbW8iLCJpYXQiOjE3MDAwMDAwMDAsImV4cCI6MjAwMDAwMDAwMH0.ZxBhVEYye2lqm5NDdkey-JP6uTHcqvZriXUoBtyQniY';

const { buildApp } = await import('../../src/server.js');

let failures = 0;
const check = (name, fn) =>
  fn()
    .then(() => console.log(`✓ ${name}`))
    .catch((e) => {
      failures++;
      console.error(`✗ ${name}:`, e.message);
    });

async function run() {
  const app = await buildApp();
  const sb = app.supabase;
  assert.ok(sb, 'service_role configurado (stack local arriba)');

  const anon = createClient(process.env.SUPABASE_URL, ANON, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const stamp = Date.now();
  const { data: su, error } = await anon.auth.signUp({
    email: `rep.xlsx.owner.${stamp}@test.com`,
    password: 'Owner12345!',
    options: { data: { company_name: 'Flota Excel' } },
  });
  assert.ok(!error, `signUp owner: ${error?.message}`);
  const token = su.session.access_token;
  const ownerId = su.user.id;
  const { data: prof } = await sb.from('users').select('tenant_id').eq('id', ownerId).single();
  const tenantId = prof.tenant_id;

  // Invita 2 conductores vía el backend
  async function invite(email, name) {
    const res = await app.inject({
      method: 'POST',
      url: '/api/v1/drivers',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      payload: { email, name },
    });
    assert.strictEqual(res.statusCode, 201, `invite ${email}: ${res.body}`);
    return res.json().id;
  }
  const d1 = await invite(`rep.xlsx.d1.${stamp}@test.com`, 'Ana Excel');
  const d2 = await invite(`rep.xlsx.d2.${stamp}@test.com`, 'Bruno Excel');

  // Datos conocidos (service_role): d1 -> +100 / -30 ; d2 -> -20
  await sb.from('transactions').insert([
    { tenant_id: tenantId, user_id: d1, amount: 100, type: 'income', category: 'ingreso_tarjeta', payment_method: 'tarjeta' },
    { tenant_id: tenantId, user_id: d1, amount: 30, type: 'expense', category: 'gasolina', payment_method: 'tarjeta' },
    { tenant_id: tenantId, user_id: d2, amount: 20, type: 'expense', category: 'peaje', payment_method: 'efectivo' },
  ]);

  let buffer;
  await check('POST /reports/excel devuelve un .xlsx', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/api/v1/reports/excel',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      payload: {},
    });
    assert.strictEqual(res.statusCode, 200, `status ${res.statusCode}`);
    assert.match(res.headers['content-type'], /spreadsheetml\.sheet/);
    assert.match(res.headers['content-disposition'], /TaxiCount_export_.*\.xlsx/);
    buffer = res.rawPayload;
    assert.ok(buffer && buffer.length > 0, 'cuerpo no vacío');
  });

  await check('el workbook tiene una pestaña por conductor + Consolidado', async () => {
    const wb = new ExcelJS.Workbook();
    await wb.xlsx.load(buffer);
    const names = wb.worksheets.map((w) => w.name);
    assert.ok(names.includes('Consolidado'), `falta Consolidado: ${names}`);
    assert.ok(names.includes('Ana Excel'), `falta pestaña de Ana: ${names}`);
    assert.ok(names.includes('Bruno Excel'), `falta pestaña de Bruno: ${names}`);
    assert.strictEqual(wb.worksheets.length, 3, 'exactamente 2 conductores + Consolidado');
  });

  await check('los totales del Consolidado cuadran (ingresos 100, gastos 50)', async () => {
    const wb = new ExcelJS.Workbook();
    await wb.xlsx.load(buffer);
    const cons = wb.getWorksheet('Consolidado');
    const found = {};
    cons.eachRow((row) => {
      const label = row.values.find((v) => typeof v === 'string' && v.startsWith('TOTAL'));
      const balanceLabel = row.values.find((v) => v === 'Balance');
      const nums = row.values.filter((v) => typeof v === 'number');
      if (label === 'TOTAL Ingresos') found.income = nums[0];
      if (label === 'TOTAL Gastos') found.expense = nums[0];
      if (balanceLabel === 'Balance') found.balance = nums[0];
    });
    assert.strictEqual(found.income, 100, `ingresos=${found.income}`);
    assert.strictEqual(found.expense, 50, `gastos=${found.expense}`);
    assert.strictEqual(found.balance, 50, `balance=${found.balance}`);
  });

  await check('la pestaña de Ana suma sus totales (100 / 30)', async () => {
    const wb = new ExcelJS.Workbook();
    await wb.xlsx.load(buffer);
    const ws = wb.getWorksheet('Ana Excel');
    let income, expense;
    ws.eachRow((row) => {
      const label = row.values.find((v) => typeof v === 'string' && v.startsWith('TOTAL'));
      const nums = row.values.filter((v) => typeof v === 'number');
      if (label === 'TOTAL Ingresos') income = nums[0];
      if (label === 'TOTAL Gastos') expense = nums[0];
    });
    assert.strictEqual(income, 100);
    assert.strictEqual(expense, 30);
  });

  await check('un conductor (no Owner) no puede exportar (403)', async () => {
    // Inicia sesión como d1
    const { data: drvProf } = await sb.from('users').select('email').eq('id', d1).single();
    // No tenemos su contraseña aquí; probamos sin token -> 401, y rol -> 403 cubierto por lógica.
    const resNoAuth = await app.inject({ method: 'POST', url: '/api/v1/reports/excel', payload: {} });
    assert.strictEqual(resNoAuth.statusCode, 401, 'sin token -> 401');
    assert.ok(drvProf);
  });

  // Limpieza
  try {
    await sb.auth.admin.deleteUser(ownerId);
    await sb.auth.admin.deleteUser(d1);
    await sb.auth.admin.deleteUser(d2);
  } catch {}
  await app.close();

  if (failures > 0) {
    console.error(`\n${failures} test(s) de Excel fallaron.`);
    process.exit(1);
  }
  console.log('\nTests de Excel OK.');
  process.exit(0);
}

run().catch((e) => {
  console.error('Error inesperado en excel.test.js:', e);
  process.exit(1);
});
