// ============================================================
// TaxiCount - Resumen POR DÍA de cada conductor para los informes Excel/PDF:
// horario (tramos), horas trabajadas, km y carreras de cada día.
//   * Si la empresa usa el registro de jornada (mig. 093) → tramos reales
//     (entrada, pausas, salida) de work_shifts/work_events.
//   * Si no → de «Iniciar día» a «Finalizar día» (lecturas de km).
//   * Si tampoco hay lecturas → de la primera a la última carrera (aprox.).
// Los km salen del registro de jornada (km de entrada y salida) o, si no, de la
// diferencia entre el km más bajo y el más alto del día (lecturas + km de las
// carreras), por coche (los km sin coche cuentan como del único coche del día).
// ============================================================
import { summarizeShift, fmtDuration } from './workday.js';
import { fmtDate, fmtTime, txDate, txTime } from './reports.js';

const MIN = 60 * 1000;

// Hora "de pared" de una pulsación de jornada (su diferencia horaria o la tz).
function wallTime(iso, off, tz) {
  if (off === null || off === undefined || !Number.isFinite(Number(off))) return fmtTime(iso, tz);
  return fmtTime(new Date(new Date(iso).getTime() + Number(off) * MIN), 'UTC');
}

// Tramos trabajados de una jornada: entrada/reanudar → pausa/salida.
export function shiftSegments(shift, tz) {
  const evs = [...(shift.work_events || [])]
    .sort((a, b) => String(a.at).localeCompare(String(b.at)) || String(a.created_at).localeCompare(String(b.created_at)));
  const off0 = evs.find((e) => e.kind === 'start')?.utc_offset_min ?? shift.utc_offset_min;
  const out = [];
  let from = null;
  for (const e of evs) {
    const t = wallTime(e.at, e.utc_offset_min ?? off0, tz);
    if (e.kind === 'start' || e.kind === 'resume') from = t;
    else if ((e.kind === 'pause' || e.kind === 'end') && from) { out.push(`${from}–${t}`); from = null; }
  }
  if (from) out.push(`${from}–…`);
  return out;
}

export const SOURCE_LABEL = {
  jornada: 'Registro de jornada',
  dia: 'Iniciar / Finalizar día',
  carreras: 'Primera y última carrera (aprox.)',
};

/**
 * Agrupa por conductor y día. Devuelve Map userId → { name, days: [día…] } con
 * los días ordenados; cada día:
 * { date, segments, workedMs, pausedMs, source, kmStart, kmEnd, km, rides, income, expense }
 */
export function buildDays({ transactions = [], shifts = [], readings = [], tz }) {
  const users = new Map();
  const dayOf = (uid, user, date) => {
    if (!users.has(uid)) users.set(uid, { name: (user && (user.name || user.email)) || 'Conductor', days: new Map() });
    const u = users.get(uid);
    if (user && (user.name || user.email) && u.name === 'Conductor') u.name = user.name || user.email;
    if (!u.days.has(date)) {
      u.days.set(date, {
        date, segments: [], workedMs: 0, pausedMs: 0, source: null,
        reads: [], txTimes: [], kmByVehicle: new Map(), shiftKm: [],
        rides: 0, income: 0, expense: 0,
      });
    }
    return u.days.get(date);
  };
  const addKm = (d, vehicle, km) => {
    if (km === null || km === undefined || !Number.isFinite(Number(km))) return;
    const k = vehicle || '-';
    if (!d.kmByVehicle.has(k)) d.kmByVehicle.set(k, []);
    d.kmByVehicle.get(k).push(Number(km));
  };

  for (const s of shifts) {
    const sum = summarizeShift(s, { tz });
    const d = dayOf(s.user_id, s.users, sum.date);
    d.source = 'jornada';
    d.segments.push(...shiftSegments(s, tz));
    d.workedMs += sum.workedMs;
    d.pausedMs += sum.pausedMs;
    if (sum.startKm != null && sum.endKm != null && sum.endKm >= sum.startKm) d.shiftKm.push([sum.startKm, sum.endKm]);
    addKm(d, s.vehicle_id, sum.startKm);
    addKm(d, s.vehicle_id, sum.endKm);
  }
  for (const r of readings) {
    const d = dayOf(r.user_id, r.users, fmtDate(r.taken_at, tz));
    d.reads.push(r.taken_at);
    addKm(d, r.vehicle_id, r.reading_km);
  }
  for (const t of transactions) {
    const d = dayOf(t.user_id, t.users, txDate(t, tz));
    if (t.type === 'income') { d.rides++; d.income += Number(t.amount); } else d.expense += Number(t.amount);
    d.txTimes.push({ iso: t.created_at, time: txTime(t, tz) });
    addKm(d, t.vehicle_id, t.odometer_km);
  }

  const out = new Map();
  for (const [uid, u] of users) {
    const days = [...u.days.values()].sort((a, b) => a.date.localeCompare(b.date));
    for (const d of days) {
      if (d.source !== 'jornada') {
        const reads = [...d.reads].sort();
        const txs = [...d.txTimes].sort((a, b) => String(a.iso).localeCompare(String(b.iso)));
        const lastTx = txs.length ? txs[txs.length - 1] : null;
        if (reads.length) {
          const start = reads[0];
          let end = reads.length > 1 ? reads[reads.length - 1] : null;
          if (!end && lastTx && lastTx.iso > start) end = lastTx.iso;
          d.source = 'dia';
          d.segments = [`${fmtTime(start, tz)}–${end ? fmtTime(end, tz) : '…'}`];
          d.workedMs = end ? new Date(end) - new Date(start) : null;
        } else if (txs.length) {
          d.source = 'carreras';
          d.segments = [`${txs[0].time}–${lastTx.time}`];
          d.workedMs = new Date(lastTx.iso) - new Date(txs[0].iso);
        }
      }
      if (d.shiftKm.length) {
        // Registro de jornada con km de entrada y salida: mandan esos.
        d.km = d.shiftKm.reduce((s, [a, b]) => s + (b - a), 0);
        d.kmStart = d.shiftKm.length === 1 ? d.shiftKm[0][0] : null;
        d.kmEnd = d.shiftKm.length === 1 ? d.shiftKm[0][1] : null;
      } else {
        // Km sin coche apuntado: si ese día solo hay un coche, son de ese coche.
        if (d.kmByVehicle.has('-') && d.kmByVehicle.size === 2) {
          const other = [...d.kmByVehicle.keys()].find((k) => k !== '-');
          d.kmByVehicle.get(other).push(...d.kmByVehicle.get('-'));
          d.kmByVehicle.delete('-');
        }
        // Por coche, del más bajo al más alto del día; se suman los coches.
        let km = 0; let any = false;
        for (const list of d.kmByVehicle.values()) {
          if (list.length >= 2) { km += Math.max(...list) - Math.min(...list); any = true; }
        }
        const all = [...d.kmByVehicle.values()];
        d.kmStart = all.length === 1 && all[0].length ? Math.min(...all[0]) : null;
        d.kmEnd = all.length === 1 && all[0].length ? Math.max(...all[0]) : null;
        d.km = any ? km : null;
      }
      delete d.reads; delete d.txTimes; delete d.kmByVehicle; delete d.shiftKm;
    }
    out.set(uid, { name: u.name, days });
  }
  return out;
}

// Totales de una lista de días.
export function daysTotals(days) {
  return days.reduce((a, d) => ({
    days: a.days + 1,
    worked: a.worked + (d.workedMs || 0),
    km: a.km + (d.km || 0),
    rides: a.rides + d.rides,
    income: a.income + d.income,
    expense: a.expense + d.expense,
  }), { days: 0, worked: 0, km: 0, rides: 0, income: 0, expense: 0 });
}

// «08:00–14:00 y 16:00–20:00»
export function segmentsLabel(segs) {
  if (!segs || !segs.length) return '';
  if (segs.length === 1) return segs[0];
  return `${segs.slice(0, -1).join(', ')} y ${segs[segs.length - 1]}`;
}

const _wd = new Intl.DateTimeFormat('es-ES', { timeZone: 'UTC', weekday: 'long' });
const _long = new Intl.DateTimeFormat('es-ES', { timeZone: 'UTC', weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
const cap = (s) => (s ? s.charAt(0).toUpperCase() + s.slice(1) : s);
// '2026-10-16' → 'Jueves'
export const weekdayOf = (date) => cap(_wd.format(new Date(`${date}T12:00:00Z`)));
// '2026-10-16' → 'Jueves, 16 de octubre de 2026'
export const longDate = (date) => cap(_long.format(new Date(`${date}T12:00:00Z`)));
// '2026-10-16' → '16/10/2026'
export const dmy = (date) => `${date.slice(8, 10)}/${date.slice(5, 7)}/${date.slice(0, 4)}`;

const _num = new Intl.NumberFormat('es-ES', { useGrouping: true });
export const kmFmt = (n) => (n === null || n === undefined ? '' : _num.format(n));
export const workedLabel = (d) => (d.workedMs === null || d.workedMs === undefined ? '' : fmtDuration(d.workedMs));
