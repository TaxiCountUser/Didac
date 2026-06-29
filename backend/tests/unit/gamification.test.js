// Tests de las funciones puras del reparto trimestral de flota (Loop #4).
// No tocan red/BD: validan la tabla de recompensa, el cálculo de trimestres y
// la detección del último día de trimestre. Las reglas RN-05/06/13/21 se
// cubren con la lógica de computeTenantQuarterMetrics + estos límites.
import assert from 'node:assert';
import {
  rewardDaysForRate, quarterOf, quarterRange, quarterLabel, isLastDayOfQuarter,
} from '../../src/gamification.js';

// Tabla de recompensa por tasa de completitud.
assert.equal(rewardDaysForRate(0), 0, '0% -> 0');
assert.equal(rewardDaysForRate(49.99), 0, '<50% -> 0');
assert.equal(rewardDaysForRate(50), 7, '50% -> 7');
assert.equal(rewardDaysForRate(74.99), 7, '74.99% -> 7');
assert.equal(rewardDaysForRate(75), 15, '75% -> 15');
assert.equal(rewardDaysForRate(89.99), 15, '89.99% -> 15');
assert.equal(rewardDaysForRate(90), 30, '90% -> 30');
assert.equal(rewardDaysForRate(100), 30, '100% -> 30');

// RN-13: la recompensa nunca supera 30 días/trimestre.
for (let r = 0; r <= 100; r += 0.5) {
  assert.ok(rewardDaysForRate(r) <= 30, 'RN-13 <= 30');
}

// DoD: 5 de 10 conductores -> 50% -> 7 días.
const rate = Math.round((5 / 10) * 10000) / 100;
assert.equal(rate, 50, 'DoD tasa 50');
assert.equal(rewardDaysForRate(rate), 7, 'DoD 5/10 -> 7 días');

// Cálculo de trimestre a partir de fecha (UTC).
assert.deepEqual(quarterOf(new Date('2026-06-29T12:00:00Z')), { year: 2026, quarter: 2 });
assert.deepEqual(quarterOf(new Date('2026-01-01T00:00:00Z')), { year: 2026, quarter: 1 });
assert.deepEqual(quarterOf(new Date('2026-12-31T23:59:00Z')), { year: 2026, quarter: 4 });

// Rango [inicio, siguiente) del trimestre.
assert.deepEqual(quarterRange(2026, 2), {
  startISO: '2026-04-01T00:00:00.000Z',
  nextISO: '2026-07-01T00:00:00.000Z',
});
assert.equal(quarterLabel(2026, 2), '2026-Q2');

// Último día de cada trimestre.
assert.equal(isLastDayOfQuarter(new Date('2026-03-31T10:00:00Z')), true, '31 mar');
assert.equal(isLastDayOfQuarter(new Date('2026-06-30T23:30:00Z')), true, '30 jun');
assert.equal(isLastDayOfQuarter(new Date('2026-09-30T10:00:00Z')), true, '30 sep');
assert.equal(isLastDayOfQuarter(new Date('2026-12-31T10:00:00Z')), true, '31 dic');
assert.equal(isLastDayOfQuarter(new Date('2026-06-29T23:30:00Z')), false, '29 jun no');
assert.equal(isLastDayOfQuarter(new Date('2026-07-01T10:00:00Z')), false, '1 jul no');

console.log('gamification.test.js OK');
