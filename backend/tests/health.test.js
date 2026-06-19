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

  // /api/v1/transcribe (mock)
  {
    const res = await app.inject({
      method: 'POST',
      url: '/api/v1/transcribe',
      payload: { audio: 'base64...' },
    });
    try {
      assert.strictEqual(res.statusCode, 200, 'POST /transcribe debe responder 200');
      const body = res.json();
      assert.ok(
        typeof body.text === 'string' && body.text.length > 0,
        'body.text debe ser un string no vacío'
      );
      console.log('✓ POST /api/v1/transcribe devuelve mock');
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
