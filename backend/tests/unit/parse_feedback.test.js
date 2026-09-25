// Tests (sin red ni BD) de classifyCorrections: cómo se clasifica cada campo que
// el usuario corrige al guardar un dictado (pestaña "Parseig").
//
//   Uso: node tests/unit/parse_feedback.test.js
import assert from 'node:assert/strict';
import { classifyCorrections } from '../../src/parse_feedback.js';

let n = 0;
const t = (name, fn) => { fn(); n++; console.log(`  ✓ ${name}`); };
const base = {
  type: 'income', amount: 50, payment_method: 'bizum', category: null,
  origin: 'Figueres', destination: 'Girona', client_name: null, odometer_km: null,
};

t('sin cambios: sin correcciones', () => {
  const c = classifyCorrections({ text: 'Figueres Girona 50 euros bizum', det: base, llm: null, proposed: base, saved: { ...base } });
  assert.deepEqual(c, {});
});
t('mayúsculas/acentos no cuentan como corrección', () => {
  const c = classifyCorrections({ text: 'x', det: base, llm: null, proposed: base, saved: { ...base, origin: 'figueres ' } });
  assert.deepEqual(c, {});
});
t('merge: el determinista lo tenía y la mezcla no', () => {
  const proposed = { ...base, amount: 35 };
  const c = classifyCorrections({ text: '35 con 50', det: { ...base, amount: 35.5 }, llm: { ...base, amount: 35 }, proposed, saved: { ...base, amount: 35.5 } });
  assert.equal(c.amount.stage, 'merge');
  assert.equal(c.amount.kind, 'wrong');
});
t('interpretation: el texto lo decía pero nadie lo sacó', () => {
  const proposed = { ...base, origin: null, destination: null };
  const c = classifyCorrections({
    text: 'Sant Pere Pescador Figueres 30 euros', det: proposed, llm: proposed, proposed,
    saved: { ...base, origin: 'Sant Pere Pescador', destination: 'Figueres' },
  });
  assert.equal(c.origin.stage, 'interpretation');
  assert.equal(c.origin.kind, 'missing');
});
t('transcription: el valor ni aparece en el texto', () => {
  const proposed = { ...base, client_name: 'Gitasi' };
  const c = classifyCorrections({
    text: 'carrera jitaxis 20 euros', det: proposed, llm: proposed, proposed, saved: { ...base, client_name: 'Movitaxi' },
  });
  assert.equal(c.client_name.stage, 'transcription');
});
t('una letra de diferencia sigue contando como "aparece"', () => {
  const proposed = { ...base, client_name: null };
  const c = classifyCorrections({
    text: '30 euros transport puig', det: proposed, llm: null, proposed, saved: { ...base, client_name: 'Transports Puig' },
  });
  assert.equal(c.client_name.stage, 'interpretation');
});
t('importe 0 = no dicho (missing)', () => {
  const proposed = { ...base, amount: 0 };
  const c = classifyCorrections({ text: 'x', det: proposed, llm: null, proposed, saved: { ...base, amount: 20 } });
  assert.equal(c.amount.kind, 'missing');
});
t('gastos: no se evalúan ruta/empresa; ingresos: no la categoría', () => {
  const exp = { ...base, type: 'expense', category: 'gasolina', origin: null, destination: null };
  const c = classifyCorrections({ text: 'x', det: exp, llm: null, proposed: exp, saved: { ...exp, origin: 'Algo' } });
  assert.deepEqual(c, {});
  const c2 = classifyCorrections({ text: 'x', det: base, llm: null, proposed: { ...base, category: 'ingreso_tarjeta' }, saved: { ...base, category: null } });
  assert.deepEqual(c2, {});
});
t('extra: se propuso algo y el usuario lo quitó', () => {
  const c = classifyCorrections({ text: 'x', det: base, llm: null, proposed: base, saved: { ...base, client_name: null, destination: null } });
  assert.equal(c.destination.kind, 'extra');
});

console.log(`\nparse_feedback.test.js OK (${n})`);
