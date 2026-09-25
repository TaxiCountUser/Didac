// Tests (sin red) de mergeParsed y needsLlm: qué manda en cada campo cuando se
// combinan el determinista y el LLM, y cuándo se puede ahorrar la llamada al LLM.
//
//   Uso: node tests/unit/parse_merge.test.js
import assert from 'node:assert/strict';
import { parseTransactionText, needsLlm } from '../../src/parser.js';
import { mergeParsed } from '../../src/llm_parser.js';

const NULL_LLM = {
  type: null, amount: null, payment_method: null, origin: null, destination: null,
  odometer_km: null, client_name: null, category: null,
};
const llm = (o) => ({ ...NULL_LLM, ...o });
let n = 0;
const t = (name, fn) => { fn(); n++; console.log(`  ✓ ${name}`); };

console.log('mergeParsed');
t('el importe del determinista manda ("35 con 50")', () => {
  const det = parseTransactionText('35 con 50 de gasoil pagado con tarjeta');
  const m = mergeParsed(llm({ amount: 35, type: 'expense', category: 'gasoil' }), det);
  assert.equal(m.amount, 35.5);
});
t('la categoría del determinista manda (gasolina, no gasoil)', () => {
  const det = parseTransactionText('treinta y cinco de gasolina');
  const m = mergeParsed(llm({ amount: 35, type: 'expense', category: 'gasoil' }), det);
  assert.equal(m.category, 'gasolina');
});
t('tipo explícito del determinista manda ("pagué 15" = gasto)', () => {
  const det = parseTransactionText('pagué 15');
  const m = mergeParsed(llm({ amount: 15, type: 'income' }), det);
  assert.equal(m.type, 'expense');
});
t('tipo por defecto: manda el LLM', () => {
  const det = parseTransactionText('50 euros');
  assert.equal(det.type_confident, false);
  const m = mergeParsed(llm({ amount: 50, type: 'expense', category: 'taller' }), det);
  assert.equal(m.type, 'expense');
  assert.equal(m.category, 'taller');
});
t('gasto del LLM sin categoría no hereda "ingreso_tarjeta"', () => {
  const det = parseTransactionText('50 euros');
  const m = mergeParsed(llm({ amount: 50, type: 'expense' }), det);
  assert.equal(m.category, null);
});
t('origen/destino/empresa: manda el LLM', () => {
  const det = parseTransactionText('de la Rambla de Figueres a l\'Estació de Renfe 9 euros');
  const m = mergeParsed(llm({ origin: 'Rambla de Figueres', destination: 'Estació de Renfe', client_name: 'Gitaxi' }), det);
  assert.equal(m.destination, 'Estació de Renfe');
  assert.equal(m.client_name, 'Gitaxi');
});
t('el LLM rellena lo que el determinista no encontró', () => {
  const det = parseTransactionText('Sant Pere Pescador Figueres 30 euros');
  const m = mergeParsed(llm({ origin: 'Sant Pere Pescador', destination: 'Figueres' }), det);
  assert.equal(m.origin, 'Sant Pere Pescador');
  assert.equal(m.amount, 30);
});

t('ruta supuesta: si el LLM dice que no hay ruta, no la hay', () => {
  const det = parseTransactionText('30 euros Transports Puig amb targeta');
  assert.equal(det.route_guess, true);
  const m = mergeParsed(llm({ amount: 30, client_name: 'Transports Puig' }), det);
  assert.equal(m.origin, null);
  assert.equal(m.destination, null);
  assert.equal(m.client_name, 'Transports Puig');
});

console.log('needsLlm');
const skip = (text, vocab) => !needsLlm(text, parseTransactionText(text, vocab), vocab);
t('frase completa y explicada: sin LLM', () => {
  assert.ok(skip('de Figueres a Girona 50 euros amb bizum'));
  assert.ok(skip('40 euros en efectivo'));
  assert.ok(skip('50 euros de gasolina'));
  assert.ok(skip('carrera Gitaxi 20 euros amb targeta'));
});
t('falta pago o importe: con LLM', () => {
  assert.ok(!skip('de Figueres a Girona 50 euros'));
  assert.ok(!skip('de Figueres a Girona amb bizum'));
});
t('ruta supuesta (dos nombres sin conector): con LLM', () => {
  assert.ok(!skip('Figueres Girona 50€ pagat amb Bizu'));
  assert.ok(skip('Figueres Girona 50€ pagat amb Bizu', { places: ['Figueres', 'Girona'] }));
});
t('queda un lugar/empresa sin colocar: con LLM', () => {
  assert.ok(!skip('carrera a l\'aeroport 60 euros amb targeta'));
  assert.ok(!skip('Sant Pere Pescador Figueres 30 euros amb bizum'));
  assert.ok(!skip('30 euros Transports Puig amb targeta'));
});
t('empresa del vocabulario: sin LLM', () => {
  assert.ok(skip('30 euros Transports Puig amb targeta', { clients: ['Transports Puig'] }));
});

console.log(`\nparse_merge.test.js OK (${n})`);
