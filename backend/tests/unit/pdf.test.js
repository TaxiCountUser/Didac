// Test del endpoint POST /api/v1/reports/pdf: genera el PDF y extrae el texto
// con pdf-parse para verificar cabecera, nombres de conductor e importes.
// Requiere el stack local. Sin Internet.
import assert from 'node:assert';
import { PDFParse } from 'pdf-parse';
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
    email: `rep.pdf.owner.${stamp}@test.com`,
    password: 'Owner12345!',
    options: { data: { company_name: 'Flota PDF' } },
  });
  assert.ok(!error, `signUp owner: ${error?.message}`);
  const token = su.session.access_token;
  const ownerId = su.user.id;
  const { data: prof } = await sb.from('users').select('tenant_id').eq('id', ownerId).single();
  const tenantId = prof.tenant_id;

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
  const d1 = await invite(`rep.pdf.d1.${stamp}@test.com`, 'Carla PDF');
  const d2 = await invite(`rep.pdf.d2.${stamp}@test.com`, 'Diego PDF');

  await sb.from('transactions').insert([
    { tenant_id: tenantId, user_id: d1, amount: 100, type: 'income', category: 'ingreso_tarjeta', payment_method: 'tarjeta' },
    { tenant_id: tenantId, user_id: d1, amount: 30, type: 'expense', category: 'gasolina', payment_method: 'tarjeta' },
    { tenant_id: tenantId, user_id: d2, amount: 20, type: 'expense', category: 'peaje', payment_method: 'efectivo' },
  ]);

  let text = '';
  await check('POST /reports/pdf devuelve un application/pdf', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/api/v1/reports/pdf',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      payload: {},
    });
    assert.strictEqual(res.statusCode, 200, `status ${res.statusCode}`);
    assert.match(res.headers['content-type'], /application\/pdf/);
    assert.match(res.headers['content-disposition'], /TaxiCount_export_.*\.pdf/);
    const buffer = res.rawPayload;
    assert.ok(buffer && buffer.length > 0 && buffer.slice(0, 4).toString() === '%PDF', 'es un PDF');
    const parsed = await new PDFParse({ data: buffer }).getText();
    text = parsed.text.replace(/\s+/g, ' ');
  });

  await check('el PDF contiene cabecera, flota y conductores', async () => {
    assert.ok(text.includes('Informe TaxiCount'), 'falta el título');
    assert.ok(text.includes('Flota PDF'), 'falta el nombre de la flota');
    assert.ok(text.includes('Carla PDF'), 'falta el conductor Carla');
    assert.ok(text.includes('Diego PDF'), 'falta el conductor Diego');
  });

  await check('el PDF contiene los importes del resumen', async () => {
    assert.ok(text.includes('100.00'), `falta 100.00 en: ${text.slice(0, 200)}`);
    assert.ok(text.includes('50.00'), 'falta el total/balance 50.00');
  });

  // Limpieza
  try {
    await sb.auth.admin.deleteUser(ownerId);
    await sb.auth.admin.deleteUser(d1);
    await sb.auth.admin.deleteUser(d2);
  } catch {}
  await app.close();

  if (failures > 0) {
    console.error(`\n${failures} test(s) de PDF fallaron.`);
    process.exit(1);
  }
  console.log('\nTests de PDF OK.');
  process.exit(0);
}

run().catch((e) => {
  console.error('Error inesperado en pdf.test.js:', e);
  process.exit(1);
});
