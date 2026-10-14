// Tests (sin red) del registro de jornada en el servidor (workday.js): cálculo de
// entrada / pausas / salida / horas / km, correcciones y que el Excel/PDF se generen.
//
//   Uso: node tests/unit/workday.test.js
import assert from 'node:assert/strict';
import ExcelJS from 'exceljs';
import { summarizeShift, fmtDuration, buildWorkdayExcel, buildWorkdayPdf } from '../../src/workday.js';

const ev = (kind, at, extra = {}) => ({ kind, at, utc_offset_min: 120, created_at: at, ...extra });
const shift = {
  status: 'closed', started_at: '2026-10-14T06:00:00Z', user_id: 'u1', users: { name: 'Pepe' },
  work_events: [
    ev('end', '2026-10-14T16:00:00Z', { km: 32610 }),
    ev('start', '2026-10-14T06:00:00Z', { km: 32442 }),
    ev('pause', '2026-10-14T11:00:00Z'),
    ev('resume', '2026-10-14T12:00:00Z', { original_at: '2026-10-14T12:10:00Z', corrected_at: '2026-10-15T08:00:00Z', correction_reason: 'Se olvidó de reanudar' }),
  ],
};

const s = summarizeShift(shift);
assert.equal(s.date, '2026-10-14');
assert.equal(s.start, '08:00'); // 06:00 UTC + 120 min = hora de España
assert.equal(s.end, '18:00');
assert.deepEqual(s.pauses, ['13:00–14:00']);
assert.equal(fmtDuration(s.workedMs), '9 h 00 min');
assert.equal(fmtDuration(s.pausedMs), '1 h 00 min');
assert.equal(s.km, 168);
assert.equal(s.corrections.length, 1);
assert.match(s.corrections[0], /14:10 → 14:00 \(Se olvidó de reanudar\)/);

// Abierta y en pausa: cuenta hasta "ahora".
const open = summarizeShift({
  status: 'paused', started_at: '2026-10-14T06:00:00Z',
  work_events: [ev('start', '2026-10-14T06:00:00Z'), ev('pause', '2026-10-14T08:00:00Z')],
}, { now: Date.parse('2026-10-14T09:00:00Z') });
assert.equal(fmtDuration(open.workedMs), '2 h 00 min');
assert.deepEqual(open.pauses, ['10:00–…']);
assert.equal(open.end, '');

// Excel: una pestaña por persona con la cabecera y la fila.
const xbuf = await buildWorkdayExcel({ tenantName: 'Flota', rangeLabel: 'oct', shifts: [shift] });
const wb = new ExcelJS.Workbook();
await wb.xlsx.load(xbuf);
const ws = wb.getWorksheet('Pepe');
assert.ok(ws, 'falta la pestaña de Pepe');
assert.equal(ws.getRow(1).getCell(1).value, 'Fecha');
assert.equal(ws.getRow(2).getCell(2).value, '08:00');
assert.equal(ws.getRow(2).getCell(6).value, '9 h 00 min');

// PDF: se genera.
const pbuf = await buildWorkdayPdf({ tenantName: 'Flota', rangeLabel: 'oct', shifts: [shift] });
assert.equal(pbuf.slice(0, 4).toString(), '%PDF');

console.log('workday: OK');
