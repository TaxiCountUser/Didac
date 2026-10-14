// ============================================================
// TaxiCount - Registro de jornada legal (mig. 093/094), parte del servidor:
//   * summarizeShift: entrada, pausas, salida, horas trabajadas y km de una
//     jornada a partir de sus pulsaciones (igual que util/workday.dart).
//   * Exportación Excel/PDF: POST /api/v1/reports/workday/:format
//     (jefe: toda la empresa o un conductor; conductor: SOLO lo suyo, que la ley
//     le da derecho a consultarlo).
//   * Avisos push cada 5 min (una vez cada uno): pausa abierta > 2 h (al
//     conductor) y jornada abierta > 12 h (al conductor y a su jefe).
// ============================================================
import ExcelJS from 'exceljs';
import PdfPrinter from 'pdfmake';
import { fmtDate, fmtTime } from './reports.js';

const MIN = 60 * 1000;
const HOUR = 60 * MIN;
export const LONG_PAUSE_MS = 2 * HOUR;
export const LONG_OPEN_MS = 12 * HOUR;

// Hora "de pared" de una pulsación: su instante + la diferencia horaria del móvil
// al pulsar (si no la hay, la zona de quien pide el informe).
function wall(iso, off, tz) {
  if (off === null || off === undefined || !Number.isFinite(Number(off))) {
    return { date: fmtDate(iso, tz), time: fmtTime(iso, tz) };
  }
  const w = new Date(new Date(iso).getTime() + Number(off) * MIN);
  return { date: fmtDate(w, 'UTC'), time: fmtTime(w, 'UTC') };
}

export function fmtDuration(ms) {
  const m = Math.max(0, Math.round(ms / MIN));
  const h = Math.floor(m / 60);
  return h > 0 ? `${h} h ${String(m % 60).padStart(2, '0')} min` : `${m} min`;
}

/** Resumen de una jornada (fila de work_shifts con `work_events`). */
export function summarizeShift(shift, { now = Date.now(), tz } = {}) {
  const evs = [...(shift.work_events || [])]
    .sort((a, b) => String(a.at).localeCompare(String(b.at)) || String(a.created_at).localeCompare(String(b.created_at)));
  const ms = (e) => new Date(e.at).getTime();
  const start = evs.find((e) => e.kind === 'start');
  const end = [...evs].reverse().find((e) => e.kind === 'end');
  const startMs = start ? ms(start) : new Date(shift.started_at).getTime();
  const endMs = end ? ms(end) : null;
  const pauses = [];
  let open = null;
  for (const e of evs) {
    if (e.kind === 'pause') open = e;
    else if ((e.kind === 'resume' || e.kind === 'end') && open) { pauses.push([open, e]); open = null; }
  }
  if (open) pauses.push([open, null]);
  const until = endMs ?? now;
  let pausedMs = 0;
  for (const [p, r] of pauses) pausedMs += (r ? ms(r) : until) - ms(p);
  const workedMs = Math.max(0, until - startMs - pausedMs);
  const off = start?.utc_offset_min ?? shift.utc_offset_min;
  const s = wall(start ? start.at : shift.started_at, off, tz);
  const e = end ? wall(end.at, end.utc_offset_min ?? off, tz) : null;
  const startKm = start?.km ?? shift.start_km ?? null;
  const endKm = end?.km ?? shift.end_km ?? null;
  const corrections = evs.filter((x) => x.corrected_at).map((x) => {
    const was = x.original_at ? wall(x.original_at, x.utc_offset_min ?? off, tz).time : null;
    const now2 = wall(x.at, x.utc_offset_min ?? off, tz).time;
    return `${x.kind}: ${was ? `${was} → ` : ''}${now2} (${x.correction_reason || ''})`;
  });
  return {
    status: shift.status,
    date: s.date,
    start: s.time,
    end: e ? e.time : '',
    pauses: pauses.map(([p, r]) => `${wall(p.at, p.utc_offset_min ?? off, tz).time}–${r ? wall(r.at, r.utc_offset_min ?? off, tz).time : '…'}`),
    pausedMs,
    workedMs,
    startKm,
    endKm,
    km: startKm != null && endKm != null && endKm >= startKm ? endKm - startKm : null,
    corrections,
  };
}

// ---------------- Exportación ----------------
const COLS = [
  { header: 'Fecha', key: 'fecha', width: 12 },
  { header: 'Entrada', key: 'entrada', width: 9 },
  { header: 'Salida', key: 'salida', width: 9 },
  { header: 'Pausas', key: 'pausas', width: 26 },
  { header: 'Tiempo en pausa', key: 'pausa', width: 15 },
  { header: 'Horas trabajadas', key: 'trabajado', width: 16 },
  { header: 'Km inicio', key: 'km_ini', width: 11 },
  { header: 'Km fin', key: 'km_fin', width: 11 },
  { header: 'Km', key: 'km', width: 8 },
  { header: 'Estado', key: 'estado', width: 10 },
  { header: 'Correcciones (motivo)', key: 'correcciones', width: 40 },
];
const STATUS = { open: 'Abierta', paused: 'En pausa', closed: 'Cerrada' };
const rowFor = (x) => ({
  fecha: x.date, entrada: x.start, salida: x.end || '—', pausas: x.pauses.join(', '),
  pausa: x.pausedMs ? fmtDuration(x.pausedMs) : '', trabajado: fmtDuration(x.workedMs),
  km_ini: x.startKm ?? '', km_fin: x.endKm ?? '', km: x.km ?? '', estado: STATUS[x.status] || x.status,
  correcciones: x.corrections.join(' · '),
});

function groupsOf(shifts, tz) {
  const groups = new Map();
  for (const s of [...shifts].sort((a, b) => String(a.started_at).localeCompare(String(b.started_at)))) {
    const u = s.users || {};
    const name = u.name || u.email || 'Conductor';
    if (!groups.has(s.user_id)) groups.set(s.user_id, { name, rows: [] });
    groups.get(s.user_id).rows.push(summarizeShift(s, { tz }));
  }
  return groups;
}

function totalsOf(rows) {
  return {
    days: rows.length,
    worked: rows.reduce((a, r) => a + r.workedMs, 0),
    paused: rows.reduce((a, r) => a + r.pausedMs, 0),
    km: rows.reduce((a, r) => a + (r.km || 0), 0),
  };
}

const HEAD_FILL = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFEEEEEE' } };
const LINE = { style: 'thin', color: { argb: 'FFBDBDBD' } };

export async function buildWorkdayExcel({ tenantName, rangeLabel, shifts, tz }) {
  const wb = new ExcelJS.Workbook();
  wb.creator = 'TaxiCount';
  const used = new Set();
  for (const [, g] of groupsOf(shifts, tz)) {
    let name = String(g.name).replace(/[[\]:*?/\\]/g, ' ').slice(0, 31) || 'Conductor';
    for (let i = 2; used.has(name); i++) name = `${name.slice(0, 27)} (${i})`;
    used.add(name);
    const ws = wb.addWorksheet(name);
    ws.columns = COLS;
    for (const r of g.rows) ws.addRow(rowFor(r));
    const last = ws.rowCount;
    for (let r = 1; r <= last; r++) {
      for (let c = 1; c <= COLS.length; c++) {
        const cell = ws.getRow(r).getCell(c);
        if (r === 1) { cell.fill = HEAD_FILL; cell.font = { bold: true }; cell.border = { bottom: { style: 'medium' } }; } else cell.border = { bottom: LINE };
      }
    }
    const t = totalsOf(g.rows);
    ws.addRow({});
    const tot = ws.addRow({ fecha: `TOTAL ${t.days} jornadas`, trabajado: fmtDuration(t.worked), pausa: fmtDuration(t.paused), km: t.km });
    tot.font = { bold: true };
    ws.addRow({});
    ws.addRow({ fecha: `${tenantName} · Registro de jornada · ${rangeLabel}` }).font = { italic: true, color: { argb: 'FF666666' } };
    ws.pageSetup = { paperSize: 9, orientation: 'landscape', fitToPage: true, fitToWidth: 1, fitToHeight: 0, printTitlesRow: '1:1' };
  }
  if (!used.size) wb.addWorksheet('Registro').addRow(['No hay jornadas en este periodo.']);
  return Buffer.from(await wb.xlsx.writeBuffer());
}

const FONTS = { Helvetica: { normal: 'Helvetica', bold: 'Helvetica-Bold', italics: 'Helvetica-Oblique', bolditalics: 'Helvetica-BoldOblique' } };

export function buildWorkdayPdf({ tenantName, rangeLabel, shifts, tz }) {
  const content = [
    { text: 'Registro de jornada', style: 'h1' },
    { text: `Empresa: ${tenantName}`, margin: [0, 2, 0, 0] },
    { text: `Periodo: ${rangeLabel}`, margin: [0, 2, 0, 8] },
  ];
  const groups = groupsOf(shifts, tz);
  if (!groups.size) content.push({ text: 'No hay jornadas en este periodo.', italics: true });
  let first = true;
  for (const [, g] of groups) {
    content.push({ text: g.name, style: 'h2', pageBreak: first ? undefined : 'before' });
    first = false;
    const body = [COLS.map((c) => ({ text: c.header, bold: true, fillColor: '#EEEEEE' }))];
    for (const r of g.rows) {
      const x = rowFor(r);
      body.push(COLS.map((c) => String(x[c.key] ?? '')));
    }
    content.push({
      table: { headerRows: 1, widths: COLS.map((c) => (['pausas', 'correcciones'].includes(c.key) ? '*' : 'auto')), body },
      layout: 'lightHorizontalLines', fontSize: 8, margin: [0, 4, 0, 8],
    });
    const t = totalsOf(g.rows);
    content.push({ text: `TOTAL: ${t.days} jornadas · ${fmtDuration(t.worked)} trabajadas · ${fmtDuration(t.paused)} en pausa · ${t.km} km`, bold: true });
  }
  const printer = new PdfPrinter(FONTS);
  const doc = printer.createPdfKitDocument({
    pageSize: 'A4', pageOrientation: 'landscape', pageMargins: [28, 28, 28, 34],
    footer: (p, n) => ({ text: `${tenantName} · Registro de jornada · ${p} / ${n}`, alignment: 'right', fontSize: 8, margin: [0, 8, 28, 0] }),
    defaultStyle: { font: 'Helvetica', fontSize: 9 },
    styles: { h1: { fontSize: 18, bold: true }, h2: { fontSize: 13, bold: true, margin: [0, 8, 0, 4] } },
    content,
  });
  return new Promise((resolve, reject) => {
    const chunks = [];
    doc.on('data', (c) => chunks.push(c));
    doc.on('end', () => resolve(Buffer.concat(chunks)));
    doc.on('error', reject);
    doc.end();
  });
}

export function registerWorkdayRoutes(app, { supabase, getCaller, XLSX_MIME }) {
  app.post('/api/v1/reports/workday/:format', async (request, reply) => {
    const format = request.params.format;
    if (!['excel', 'pdf'].includes(format)) return reply.code(404).send({ error: 'Formato no válido' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (!caller.tenant_id) return reply.code(403).send({ error: 'Sin empresa' });
    const b = request.body ?? {};
    // El conductor SOLO puede exportar lo suyo; el jefe, cualquiera de su empresa.
    const userId = caller.role === 'owner' ? (b.userId || null) : caller.id;
    let q = supabase.from('work_shifts')
      .select('*, work_events(*), users:user_id(name, email)')
      .eq('tenant_id', caller.tenant_id);
    if (userId) q = q.eq('user_id', userId);
    if (b.from) q = q.gte('started_at', b.from);
    if (b.to) q = q.lt('started_at', b.to);
    const { data, error } = await q.order('started_at').limit(5000);
    if (error) return reply.code(500).send({ error: error.message });
    const { data: t } = await supabase.from('tenants').select('name').eq('id', caller.tenant_id).maybeSingle();
    const tz = b.tz;
    const rangeLabel = b.from || b.to
      ? `${b.from ? fmtDate(b.from, tz) : '—'} a ${b.to ? fmtDate(new Date(b.to).getTime() - 1, tz) : '—'}`
      : 'Todo';
    const args = { tenantName: t?.name || 'TaxiCount', rangeLabel, shifts: data ?? [], tz };
    const buf = format === 'excel' ? await buildWorkdayExcel(args) : await buildWorkdayPdf(args);
    const ext = format === 'excel' ? 'xlsx' : 'pdf';
    return reply
      .header('Content-Type', format === 'excel' ? XLSX_MIME : 'application/pdf')
      .header('Content-Disposition', `attachment; filename="TaxiCount_jornada_${new Date().toISOString().slice(0, 10)}.${ext}"`)
      .send(buf);
  });
}

// ---------------- Avisos push ----------------
export function createWorkdayReminders({ supabase, notifyUsers, log }) {
  let running = false;
  const hhmm = (iso, off) => wall(iso, off, 'Europe/Madrid').time;

  async function run({ now = Date.now() } = {}) {
    if (running) return { skipped: true };
    running = true;
    let sent = 0;
    try {
      const { data: tenants } = await supabase.from('tenants').select('id')
        .eq('workday_required', true).is('closed_at', null);
      const tenantIds = (tenants ?? []).map((t) => t.id);
      if (!tenantIds.length) return { sent };

      // 1) Pausa abierta más de 2 h -> al conductor (una vez por pausa).
      const { data: paused } = await supabase.from('work_shifts')
        .select('id, user_id, work_events(id, kind, at, utc_offset_min, alerted_at)')
        .in('tenant_id', tenantIds).eq('status', 'paused');
      for (const sh of paused ?? []) {
        const evs = [...(sh.work_events || [])].sort((a, b) => String(a.at).localeCompare(String(b.at)));
        const last = evs[evs.length - 1];
        if (!last || last.kind !== 'pause' || last.alerted_at) continue;
        if (now - new Date(last.at).getTime() < LONG_PAUSE_MS) continue;
        const { data: claimed } = await supabase.from('work_events').update({ alerted_at: new Date(now).toISOString() })
          .eq('id', last.id).is('alerted_at', null).select('id');
        if (!claimed?.length) continue;
        await notifyUsers([sh.user_id], 'wd_long_pause', { time: hhmm(last.at, last.utc_offset_min) }, { type: 'workday' });
        sent++;
      }

      // 2) Jornada abierta más de 12 h -> al conductor y a su(s) jefe(s).
      const { data: open } = await supabase.from('work_shifts')
        .select('id, tenant_id, user_id, started_at, utc_offset_min, users:user_id(name, email, role)')
        .in('tenant_id', tenantIds).neq('status', 'closed').is('long_open_alerted_at', null)
        .lt('started_at', new Date(now - LONG_OPEN_MS).toISOString());
      for (const sh of open ?? []) {
        const { data: claimed } = await supabase.from('work_shifts').update({ long_open_alerted_at: new Date(now).toISOString() })
          .eq('id', sh.id).is('long_open_alerted_at', null).select('id');
        if (!claimed?.length) continue;
        const time = hhmm(sh.started_at, sh.utc_offset_min);
        await notifyUsers([sh.user_id], 'wd_long_open', { time }, { type: 'workday' });
        if (sh.users?.role !== 'owner') {
          const { data: owners } = await supabase.from('users').select('id')
            .eq('tenant_id', sh.tenant_id).eq('role', 'owner').eq('active', true).is('deleted_at', null);
          const ids = (owners ?? []).map((o) => o.id).filter((id) => id !== sh.user_id);
          if (ids.length) {
            await notifyUsers(ids, 'wd_long_open_owner',
              { name: sh.users?.name || sh.users?.email || '—', time }, { type: 'workday' });
          }
        }
        sent++;
      }
      return { sent };
    } catch (e) {
      log?.warn?.(`[workday-reminders] ${e.message}`);
      return { sent, error: e.message };
    } finally {
      running = false;
    }
  }
  return { run };
}

/** Intervalo de 5 min (desactivable con WORKDAY_REMINDERS=off; no en tests). */
export function registerWorkdayReminders(app, { workdayReminders, env = process.env }) {
  if (env.WORKDAY_REMINDERS === 'off' || env.NODE_ENV === 'test') return;
  const timer = setInterval(() => {
    workdayReminders.run().catch((e) => app.log.warn(`[workday-reminders] ${e.message}`));
  }, 5 * MIN);
  timer.unref?.();
  app.addHook('onClose', async () => clearInterval(timer));
}
