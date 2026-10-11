// Tests (sin red ni BD) del asistente virtual: normalización de frases (para
// agrupar/aprender) y saneado de las respuestas que crea el admin.
//
//   Uso: node tests/unit/assistant.test.js
import assert from 'node:assert/strict';
import { normPhrase, cleanEntry } from '../../src/assistant.js';

let n = 0;
const t = (name, fn) => { fn(); n++; console.log(`  ✓ ${name}`); };

t('normPhrase: minúsculas, sin acentos ni signos', () => {
  assert.equal(normPhrase('  ¿Cómo CIERRO la jornada?? '), 'como cierro la jornada');
  assert.equal(normPhrase("No m'ha servit!"), 'no m ha servit');
});
t('normPhrase: recorta a 300', () => {
  assert.equal(normPhrase('a'.repeat(500)).length, 300);
});
t('cleanEntry: exige respuesta en español', () => {
  assert.equal(cleanEntry({ a: { ca: 'hola' } }), null);
  assert.equal(cleanEntry(null), null);
});
t('cleanEntry: preguntas por líneas, roles válidos, tutorial solo http(s)', () => {
  const e = cleanEntry({
    q: { es: 'uno\n\n dos ', en: ['three'] }, a: { es: ' Respuesta ' },
    roles: ['owner', 'hacker'], tutorial: 'javascript:alert(1)', related: ['ok_id', 'BAD ID'],
  });
  assert.deepEqual(e.q, { es: ['uno', 'dos'], en: ['three'] });
  assert.equal(e.a.es, 'Respuesta');
  assert.deepEqual(e.roles, ['owner']);
  assert.equal(e.tutorial, null);
  assert.deepEqual(e.related, ['ok_id']);
  assert.equal(cleanEntry({ a: { es: 'x' }, tutorial: 'https://youtu.be/abc' }).tutorial, 'https://youtu.be/abc');
});

console.log(`assistant: ${n} tests OK`);
