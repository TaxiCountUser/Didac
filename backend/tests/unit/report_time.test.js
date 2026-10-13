// Tests (sin red) de la hora de los informes (reports.js): el Excel/PDF deben
// decir la MISMA hora que la app, que la enseña en la zona del móvil/navegador.
//
//   Uso: node tests/unit/report_time.test.js
import assert from 'node:assert/strict';
import { fmtDate, fmtTime, safeTz, DEFAULT_TZ } from '../../src/reports.js';

// Verano (UTC+2): una carrera a las 00:30 en España es del día 2, no del 1.
assert.equal(fmtDate('2026-10-01T22:30:00Z', 'Europe/Madrid'), '2026-10-02');
assert.equal(fmtTime('2026-10-01T22:30:00Z', 'Europe/Madrid'), '00:30');
// Invierno (UTC+1).
assert.equal(fmtTime('2026-12-01T22:30:00Z', 'Europe/Madrid'), '23:30');
assert.equal(fmtDate('2026-12-01T22:30:00Z', 'Europe/Madrid'), '2026-12-01');
// Día del cambio de hora (25/10/2026, 03:00 -> 02:00).
assert.equal(fmtTime('2026-10-25T00:30:00Z', 'Europe/Madrid'), '02:30');
assert.equal(fmtTime('2026-10-25T01:30:00Z', 'Europe/Madrid'), '02:30');
// Canarias: una hora menos que la península.
assert.equal(fmtTime('2026-10-01T22:30:00Z', 'Atlantic/Canary'), '23:30');
assert.equal(fmtDate('2026-10-01T22:30:00Z', 'Atlantic/Canary'), '2026-10-01');
// Sin zona o con una zona inválida: España.
assert.equal(safeTz(undefined), DEFAULT_TZ);
assert.equal(safeTz('Marte/Olympus'), DEFAULT_TZ);
assert.equal(safeTz('x'.repeat(100)), DEFAULT_TZ);
assert.equal(fmtTime('2026-10-01T06:10:00Z'), '08:10');
assert.equal(safeTz('Atlantic/Canary'), 'Atlantic/Canary');

console.log('report_time: OK');
