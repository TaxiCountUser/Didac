// Tests (sin red) del resumen POR DÍA de los informes (report_days.js) y del
// orden/nombre de las hojas (reports.js):
//   Resumen general (diario/semanal/mensual/anual/del periodo) → una hoja por
//   conductor (por fecha y hora) → «Resumen diario conductores».
//
//   Uso: node tests/unit/report_days.test.js
import assert from 'node:assert/strict';
import ExcelJS from 'exceljs';
import { buildDays, shiftSegments, segmentsLabel, daysTotals } from '../../src/report_days.js';
import { buildExcel, buildPdf, isSingleDay, periodKind } from '../../src/reports.js';

const tz = 'Europe/Madrid';
const iso = (day, h) => new Date(`${day}T${h}:00+02:00`).toISOString(); // octubre = UTC+2
const D = '2026-10-16';
const pepe = { name: 'Pepe', email: 'p@x.com' };
const ana = { name: 'Ana', email: 'a@x.com' };
const jordi = { name: 'Jordi', email: 'j@x.com' };

// Jornada con pausa (registro de jornada): 08:00–14:00 y 16:00–20:00, km 1000→1133.
const ev = (kind, h, km = null) => ({ kind, at: iso(D, h), utc_offset_min: 120, km });
const shift = {
  user_id: 'u1', users: pepe, vehicle_id: 'v1', status: 'closed', started_at: iso(D, '08:00'),
  start_km: 1000, end_km: 1133, utc_offset_min: 120,
  work_events: [ev('start', '08:00', 1000), ev('pause', '14:00'), ev('resume', '16:00'), ev('end', '20:00', 1133)],
};
assert.deepEqual(shiftSegments(shift, tz), ['08:00–14:00', '16:00–20:00']);
assert.equal(segmentsLabel(['08:00–14:00', '16:00–20:00']), '08:00–14:00 y 16:00–20:00');

const tx = (uid, user, h, type, amount, extra = {}) => ({
  user_id: uid, users: user, vehicle_id: `v-${uid}`, created_at: iso(D, h), utc_offset_min: 120, type, amount, ...extra,
});
const transactions = [
  tx('u1', pepe, '13:10', 'income', 25, { client_name: 'mútua', odometer_km: 1100 }),
  tx('u1', pepe, '08:20', 'income', 18.5, { odometer_km: 1010 }),
  tx('u1', pepe, '12:30', 'expense', 60, { category: 'gasoil' }),
  tx('u2', ana, '09:00', 'income', 15, { odometer_km: 5050 }),
  tx('u3', jordi, '06:45', 'income', 48),
  tx('u3', jordi, '15:10', 'income', 11.5),
];
// Ana: sin registro de jornada; «Iniciar día» 07:10 (5000 km) y «Finalizar día» 19:30 (5190 km).
const readings = [
  { user_id: 'u2', users: ana, vehicle_id: 'v-u2', reading_km: 5000, taken_at: iso(D, '07:10') },
  { user_id: 'u2', users: ana, vehicle_id: 'v-u2', reading_km: 5190, taken_at: iso(D, '19:30') },
];
const days = buildDays({ transactions, shifts: [shift], readings, tz });

const p = days.get('u1').days[0];
assert.equal(p.source, 'jornada');
assert.equal(p.workedMs, 10 * 3600000);
assert.equal(p.pausedMs, 2 * 3600000);
assert.equal(p.km, 133);
assert.equal(p.rides, 2);
assert.equal(p.expense, 60);

const a = days.get('u2').days[0];
assert.equal(a.source, 'dia');
assert.deepEqual(a.segments, ['07:10–19:30']);
assert.equal(a.km, 190);
assert.equal(a.kmStart, 5000);
assert.equal(a.kmEnd, 5190);

// Jordi: ni jornada ni lecturas → de la primera a la última carrera; sin km.
const j = days.get('u3').days[0];
assert.equal(j.source, 'carreras');
assert.deepEqual(j.segments, ['06:45–15:10']);
assert.equal(j.km, null);
assert.equal(daysTotals(days.get('u3').days).income, 59.5);

// Tipo de informe según el rango.
assert.equal(isSingleDay(iso(D, '00:00'), iso('2026-10-17', '00:00'), tz), true);
assert.equal(periodKind(iso(D, '00:00'), iso('2026-10-17', '00:00'), tz), 'diario');
assert.equal(periodKind(iso('2026-10-12', '00:00'), iso('2026-10-19', '00:00'), tz), 'semanal'); // lunes a domingo
assert.equal(periodKind(iso('2026-10-01', '00:00'), new Date('2026-11-01T00:00:00+01:00').toISOString(), tz), 'mensual');
assert.equal(periodKind(new Date('2026-01-01T00:00:00+01:00').toISOString(), new Date('2027-01-01T00:00:00+01:00').toISOString(), tz), 'anual');
assert.equal(periodKind(iso('2026-10-03', '00:00'), iso('2026-10-09', '00:00'), tz), 'del periodo');
assert.equal(periodKind(undefined, undefined, tz), 'del periodo');

// Excel de UN día: orden y nombre de las hojas, y la hoja del conductor por hora.
const groups = new Map();
for (const t of transactions) {
  if (!groups.has(t.user_id)) groups.set(t.user_id, { name: t.users.name, email: t.users.email, txs: [] });
  groups.get(t.user_id).txs.push(t);
}
const data = {
  tenantName: 'Test', startDate: iso(D, '00:00'), endDate: iso('2026-10-17', '00:00'), transactions, groups, tz,
  days, singleDay: true,
};
const wb = new ExcelJS.Workbook();
await wb.xlsx.load(await buildExcel(data));
const names = wb.worksheets.map((w) => w.name);
assert.deepEqual(names, ['Resumen general (diario)', 'Pepe', 'Ana', 'Jordi', 'Resumen diario conductores']);

// Hoja de Pepe: resumen de la jornada arriba y las carreras/gastos por hora.
const ws = wb.getWorksheet('Pepe');
const texts = [];
ws.eachRow((row) => texts.push(row.values.filter((v) => typeof v === 'string').join(' | ')));
assert.match(texts[0], /Viernes, 16 de octubre de 2026 · Pepe/);
assert.match(texts.join('\n'), /Horario: 08:00–14:00 y 16:00–20:00/);
assert.match(texts.join('\n'), /de 1.000 a 1.133 · 133 km/);
const hours = [];
ws.eachRow((row) => { const h = row.getCell(2).value; if (typeof h === 'string' && /^\d\d:\d\d$/.test(h)) hours.push(h); });
assert.deepEqual(hours, ['08:20', '12:30', '13:10']);

// Hoja de un MES: el conductor también va por fecha (no por cliente) y sin resumen arriba.
const month = { ...data, startDate: iso('2026-10-01', '00:00'), endDate: new Date('2026-11-01T00:00:00+01:00').toISOString(), singleDay: false };
const wb2 = new ExcelJS.Workbook();
await wb2.xlsx.load(await buildExcel(month));
assert.equal(wb2.worksheets[0].name, 'Resumen general (mensual)');
const ws2 = wb2.getWorksheet('Pepe');
assert.equal(ws2.getRow(1).getCell(1).value, 'Fecha');
const hours2 = [];
ws2.eachRow((row) => { const h = row.getCell(2).value; if (typeof h === 'string' && /^\d\d:\d\d$/.test(h)) hours2.push(h); });
assert.deepEqual(hours2, ['08:20', '12:30', '13:10']);

// El PDF se genera con el mismo contenido.
const pdf = await buildPdf(data);
assert.ok(pdf.length > 1000);

console.log('report_days: OK');
