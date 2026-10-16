// Genera Excel y PDF de EJEMPLO (datos inventados) para ver cómo salen los
// informes sin tocar la base de datos:
//   * informe-dia.*  → informe de UN día (por orden de hora + resumen de la jornada)
//   * informe-mes.*  → informe de un mes (+ hoja «Resumen diario»)
//   Uso: node tests/make_report_samples.js <carpeta_salida>
import { writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { buildExcel, buildPdf, isSingleDay } from '../src/reports.js';
import { buildDays } from '../src/report_days.js';

const out = process.argv[2] || '.';
mkdirSync(out, { recursive: true });
const tz = 'Europe/Madrid';
const OFF = 120; // octubre: España = UTC+2

const pepe = { name: 'Pepe García', email: 'pepe@example.com' };
const ana = { name: 'Ana Puig', email: 'ana@example.com' };
const jordi = { name: 'Jordi Vila', email: 'jordi@example.com' }; // sin registro ni km
let n = 0;
// h = hora LOCAL «HH:MM» del día `day` (AAAA-MM-DD).
const iso = (day, h) => new Date(`${day}T${h}:00+02:00`).toISOString();
const tx = (user, uid, day, h, type, amount, extra = {}) => ({
  id: `t${++n}`, user_id: uid, users: user, vehicle_id: uid === 'u1' ? 'v1' : 'v2',
  created_at: iso(day, h), utc_offset_min: OFF, type, amount, ...extra,
});
// Jornada con registro: tramos [[entrada, pausa], [reanudar, salida]] y km.
const shift = (user, uid, day, segs, kmIni, kmFin) => {
  const ev = [];
  segs.forEach(([a, b], i) => {
    ev.push({ kind: i === 0 ? 'start' : 'resume', at: iso(day, a), utc_offset_min: OFF, km: i === 0 ? kmIni : null });
    ev.push({ kind: i === segs.length - 1 ? 'end' : 'pause', at: iso(day, b), utc_offset_min: OFF, km: i === segs.length - 1 ? kmFin : null });
  });
  return { user_id: uid, users: user, vehicle_id: 'v1', status: 'closed', started_at: iso(day, segs[0][0]), start_km: kmIni, end_km: kmFin, utc_offset_min: OFF, work_events: ev };
};
const reading = (user, uid, day, h, km) => ({ user_id: uid, users: user, vehicle_id: 'v2', reading_km: km, taken_at: iso(day, h) });

function dataFor(transactions, shifts, readings, startDate, endDate) {
  const groups = new Map();
  for (const t of transactions) {
    if (!groups.has(t.user_id)) groups.set(t.user_id, { name: t.users.name, email: t.users.email, txs: [] });
    groups.get(t.user_id).txs.push(t);
  }
  return {
    tenantName: 'Taxis Empordà (ejemplo)', startDate, endDate, transactions, groups, tz,
    days: buildDays({ transactions, shifts, readings, tz }), singleDay: isSingleDay(startDate, endDate, tz),
  };
}

// ---- Un día: 16/10/2026 ----
const D = '2026-10-16';
const dayTx = [
  tx(pepe, 'u1', D, '08:20', 'income', 18.5, { origin: 'Estació de Figueres', destination: 'Hospital de Figueres', odometer_km: 32460, payment_method: 'efectivo' }),
  tx(pepe, 'u1', D, '09:45', 'income', 42, { origin: 'Roses', destination: 'Aeropuerto de Girona', odometer_km: 32510, client_name: 'hotel almadraba', payment_method: 'credito' }),
  tx(pepe, 'u1', D, '12:30', 'expense', 60, { category: 'gasoil', payment_method: 'tarjeta' }),
  tx(pepe, 'u1', D, '13:10', 'income', 25, { origin: 'Llançà', destination: 'Figueres', odometer_km: 32540, client_name: 'mútua', payment_method: 'credito' }),
  tx(pepe, 'u1', D, '17:05', 'income', 12, { origin: 'La Rambla', destination: 'Vilafant', odometer_km: 32555, payment_method: 'tarjeta' }),
  tx(pepe, 'u1', D, '19:30', 'expense', 8, { category: 'lavado', payment_method: 'efectivo' }),
  tx(ana, 'u2', D, '07:40', 'income', 15, { origin: 'Plaça Catalunya', destination: 'Avinyonet', odometer_km: 118215, payment_method: 'bizum' }),
  tx(ana, 'u2', D, '11:15', 'expense', 45, { category: 'otros', description: 'ITV', payment_method: 'tarjeta' }),
  tx(ana, 'u2', D, '16:05', 'income', 33, { origin: 'Cadaqués', destination: 'Estació AVE Figueres-Vilafant', odometer_km: 118300, payment_method: 'efectivo' }),
];
const dayShifts = [shift(pepe, 'u1', D, [['08:00', '14:00'], ['16:00', '20:00']], 32442, 32575)];
const dayReads = [reading(ana, 'u2', D, '07:10', 118200), reading(ana, 'u2', D, '19:30', 118390)];
const day = dataFor(dayTx, dayShifts, dayReads, iso(D, '00:00'), iso('2026-10-17', '00:00'));
writeFileSync(join(out, 'informe-dia.xlsx'), await buildExcel(day));
writeFileSync(join(out, 'informe-dia.pdf'), await buildPdf(day));

// ---- Un mes: octubre 2026 (algunos días) ----
const monthTx = [];
const monthShifts = [];
const monthReads = [];
let kmP = 31800;
let kmA = 117600;
for (const dd of ['01', '02', '05', '06', '07', '08', '09', '12', '13', '14', '15', '16']) {
  const day2 = `2026-10-${dd}`;
  const k = 90 + (Number(dd) * 7) % 60;
  monthShifts.push(shift(pepe, 'u1', day2, [['08:00', '14:00'], ['16:00', Number(dd) % 2 ? '20:00' : '19:15']], kmP, kmP + k));
  monthTx.push(tx(pepe, 'u1', day2, '09:10', 'income', 20 + Number(dd), { origin: 'Figueres', destination: 'Roses', odometer_km: kmP + 30, payment_method: 'efectivo' }));
  monthTx.push(tx(pepe, 'u1', day2, '17:40', 'income', 35, { origin: 'Girona', destination: 'Figueres', odometer_km: kmP + 80, client_name: 'mútua', payment_method: 'credito' }));
  if (Number(dd) % 3 === 0) monthTx.push(tx(pepe, 'u1', day2, '13:00', 'expense', 55, { category: 'gasoil', payment_method: 'tarjeta' }));
  kmP += k;
  if (Number(dd) % 2 === 0) {
    const ka = 120 + (Number(dd) * 11) % 70;
    monthReads.push(reading(ana, 'u2', day2, '07:05', kmA), reading(ana, 'u2', day2, '18:50', kmA + ka));
    monthTx.push(tx(ana, 'u2', day2, '10:30', 'income', 28, { origin: 'Cadaqués', destination: 'Figueres', odometer_km: kmA + 40, payment_method: 'bizum' }));
    kmA += ka;
  }
  if (Number(dd) % 3 !== 1) {
    monthTx.push(tx(jordi, 'u3', day2, '06:45', 'income', 48, { origin: 'Figueres', destination: 'Aeropuerto de Girona', client_name: 'hotel almadraba', payment_method: 'credito' }));
    monthTx.push(tx(jordi, 'u3', day2, '12:20', 'income', 16, { origin: 'Hospital de Figueres', destination: 'Vilafant', client_name: 'hospital', payment_method: 'credito' }));
    monthTx.push(tx(jordi, 'u3', day2, '15:10', 'income', 11.5, { origin: 'La Rambla', destination: 'Estació', payment_method: 'tarjeta' }));
  }
}
const month = dataFor(monthTx, monthShifts, monthReads, iso('2026-10-01', '00:00'), iso('2026-11-01', '00:00'));
writeFileSync(join(out, 'informe-mes.xlsx'), await buildExcel(month));
writeFileSync(join(out, 'informe-mes.pdf'), await buildPdf(month));
console.log('ok', out);
