// Test ligero del endpoint /health usando fastify.inject (sin abrir puerto).
import assert from 'node:assert';
import { buildApp } from '../src/server.js';

process.env.NODE_ENV = 'test';

let failures = 0;

async function run() {
  const app = await buildApp();

  // /health
  {
    const res = await app.inject({ method: 'GET', url: '/health' });
    try {
      assert.strictEqual(res.statusCode, 200, 'GET /health debe responder 200');
      const body = res.json();
      assert.strictEqual(body.status, 'ok', "body.status debe ser 'ok'");
      assert.ok(body.timestamp, 'body.timestamp debe existir');
      console.log('✓ GET /health responde 200 con status ok');
    } catch (e) {
      failures++;
      console.error('✗ /health:', e.message);
    }
  }

  // /api/v1/transcribe exige autenticación (Fase 2): sin JWT -> 401.
  {
    const res = await app.inject({
      method: 'POST',
      url: '/api/v1/transcribe',
      headers: { 'content-type': 'application/json' },
      payload: { mock_text: 'x' },
    });
    try {
      assert.strictEqual(res.statusCode, 401, 'POST /transcribe sin JWT debe responder 401');
      console.log('✓ POST /api/v1/transcribe exige autenticación');
    } catch (e) {
      failures++;
      console.error('✗ /api/v1/transcribe:', e.message);
    }
  }

  await app.close();

  if (failures > 0) {
    console.error(`\n${failures} test(s) fallaron.`);
    process.exit(1);
  }
  console.log('\nTodos los tests del backend pasaron.');
  process.exit(0);
}

run().catch((err) => {
  console.error('Error inesperado en los tests:', err);
  process.exit(1);
});
