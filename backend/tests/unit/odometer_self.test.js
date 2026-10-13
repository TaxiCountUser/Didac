// Tests (sin red) de la corrección de km por el propio cliente (odometer.js):
// solo a la baja, nunca bajo el km inicial, cada uno lo suyo y el jefe su flota.
//
//   Uso: node tests/unit/odometer_self.test.js
import assert from 'node:assert/strict';
import { checkSelfCorrection as check } from '../../src/odometer.js';

const driver = { id: 'u1', role: 'driver', tenant_id: 't1' };
const owner = { id: 'boss', role: 'owner', tenant_id: 't1' };
const mine = { tenant_id: 't1', user_id: 'u1', km: 324423 };
const other = { tenant_id: 't1', user_id: 'u2', km: 324423 };
const foreign = { tenant_id: 't2', user_id: 'u1', km: 324423 };

// El conductor baja su km equivocado.
assert.equal(check({ caller: driver, row: mine, newKm: 32442, initialKm: 30000 }), null);
// Subirlo o dejarlo igual, NO (inflaría el reto de km).
assert.equal(check({ caller: driver, row: mine, newKm: 400000, initialKm: 30000 }), 'km_not_lower');
assert.equal(check({ caller: driver, row: mine, newKm: 324423, initialKm: 30000 }), 'km_not_lower');
// Nunca por debajo del km inicial del coche.
assert.equal(check({ caller: driver, row: mine, newKm: 29999, initialKm: 30000 }), 'km_below_initial');
assert.equal(check({ caller: driver, row: mine, newKm: -1, initialKm: null }), 'km_invalid');
assert.equal(check({ caller: driver, row: mine, newKm: NaN, initialKm: null }), 'km_invalid');
// El conductor no toca los de otro; el jefe sí (de su empresa).
assert.equal(check({ caller: driver, row: other, newKm: 32442, initialKm: null }), 'forbidden');
assert.equal(check({ caller: owner, row: other, newKm: 32442, initialKm: null }), null);
// Nadie toca los de otra empresa.
assert.equal(check({ caller: owner, row: foreign, newKm: 32442, initialKm: null }), 'forbidden');
assert.equal(check({ caller: { ...owner, tenant_id: null }, row: foreign, newKm: 1, initialKm: null }), 'forbidden');
// Borrar se permite con los mismos permisos.
assert.equal(check({ caller: driver, row: mine, newKm: null, initialKm: null }), null);
assert.equal(check({ caller: driver, row: other, newKm: null, initialKm: null }), 'forbidden');
assert.equal(check({ caller: driver, row: undefined, newKm: 1, initialKm: null }), 'not_found');

console.log('odometer_self: OK');
