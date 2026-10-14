import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import '../services/file_download.dart';
import '../util/error_ui.dart';
import '../util/format.dart' show wallToUtc;
import '../util/workday.dart';

/// Registro de jornada (mig. 093/094). El conductor ve SU registro (lo exige la
/// ley) y lo puede exportar; el jefe / autónomo ve el de cualquiera de su empresa
/// (selector), lo exporta y CORRIGE con motivo (o cierra una jornada olvidada).
/// Por día: entrada, pausas, salida, horas trabajadas y km; total del mes.
class WorkdayLogScreen extends StatefulWidget {
  final Profile profile;
  const WorkdayLogScreen({super.key, required this.profile});

  @override
  State<WorkdayLogScreen> createState() => _WorkdayLogScreenState();
}

class _WorkdayLogScreenState extends State<WorkdayLogScreen> {
  final _service = DataService();
  late DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  String? _userId; // null = todos (solo jefe)
  List<Map<String, dynamic>> _drivers = const [];
  Future<List<Map<String, dynamic>>>? _future;
  bool _exporting = false;

  bool get _isOwner => widget.profile.isOwner;
  DateTime get _monthEnd => DateTime(_month.year, _month.month + 1);

  @override
  void initState() {
    super.initState();
    _userId = _isOwner ? null : widget.profile.id;
    if (_isOwner) _loadDrivers();
    _reload();
  }

  Future<void> _loadDrivers() async {
    try {
      final d = await _service.listDrivers();
      if (mounted) setState(() => _drivers = d);
    } catch (_) {}
  }

  void _reload() {
    setState(() {
      _future = _service.listShifts(userId: _userId, from: _month, to: _monthEnd);
    });
  }

  void _moveMonth(int delta) {
    _month = DateTime(_month.year, _month.month + delta);
    _reload();
  }

  Future<void> _export(String format) async {
    final l = context.l10n;
    setState(() => _exporting = true);
    try {
      final bytes = await _service.downloadWorkdayReport(
          format: format, from: _month, to: _monthEnd, userId: _userId);
      final ext = format == 'excel' ? 'xlsx' : 'pdf';
      await saveAndOpenDownload(bytes,
          'taxicount_jornada_${DateFormat('yyyy-MM').format(_month)}.$ext');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('od_generated'))));
      }
    } catch (e) {
      if (mounted) showError(context, e, screen: 'WorkdayLog');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final monthLabel = DateFormat('MMMM yyyy', 'es').format(_month);
    return Scaffold(
      appBar: AppBar(
        title: Text(l.t('wd_log_title')),
        actions: [
          if (_exporting)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            PopupMenuButton<String>(
              tooltip: l.t('wd_export'),
              icon: const Icon(Icons.download),
              onSelected: _export,
              itemBuilder: (_) => [
                PopupMenuItem(value: 'excel', child: Text(l.t('wd_export_excel'))),
                PopupMenuItem(value: 'pdf', child: Text(l.t('wd_export_pdf'))),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          // Mes (anterior / siguiente) y, para el jefe, de quién.
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(children: [
              IconButton(onPressed: () => _moveMonth(-1), icon: const Icon(Icons.chevron_left)),
              Expanded(
                child: Text(monthLabel[0].toUpperCase() + monthLabel.substring(1),
                    textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
              ),
              IconButton(onPressed: () => _moveMonth(1), icon: const Icon(Icons.chevron_right)),
            ]),
          ),
          if (_isOwner)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButtonFormField<String?>(
                initialValue: _userId,
                isExpanded: true,
                decoration: InputDecoration(labelText: l.t('wd_log_who')),
                items: [
                  DropdownMenuItem(value: null, child: Text(l.t('wd_log_all'))),
                  DropdownMenuItem(value: widget.profile.id, child: Text(widget.profile.appName)),
                  for (final d in _drivers)
                    if (d['id'] != widget.profile.id)
                      DropdownMenuItem(
                          value: d['id'] as String,
                          child: Text((d['name'] as String?)?.isNotEmpty == true
                              ? d['name'] as String
                              : (d['email'] as String? ?? '—'))),
                ],
                onChanged: (v) {
                  _userId = v;
                  _reload();
                },
              ),
            ),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(child: Text('${l.t('error')}: ${snap.error}'));
                }
                final shifts = snap.data ?? const [];
                if (shifts.isEmpty) {
                  return Center(child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(l.t('wd_log_empty'), textAlign: TextAlign.center),
                  ));
                }
                final sums = shifts.map(WorkdaySummary.fromShift).toList();
                var total = Duration.zero;
                var km = 0;
                for (final s in sums) {
                  total += s.worked();
                  km += s.km ?? 0;
                }
                return RefreshIndicator(
                  onRefresh: () async => _reload(),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    children: [
                      Card(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            l.t('wd_log_total', {'n': '${sums.length}', 'worked': fmtWorked(total), 'km': '$km'}),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                      for (var i = 0; i < shifts.length; i++) _shiftCard(l, shifts[i], sums[i]),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  List<Map<String, dynamic>> _events(Map<String, dynamic> shift) =>
      ((shift['work_events'] as List?) ?? const []).cast<Map<String, dynamic>>().toList()
        ..sort((a, b) => '${a['at']}'.compareTo('${b['at']}'));

  Widget _shiftCard(AppLocalizations l, Map<String, dynamic> shift, WorkdaySummary s) {
    final hm = DateFormat('HH:mm');
    final day = DateFormat('EEEE d MMM', 'es').format(s.start);
    final who = _isOwner && _userId == null
        ? (((shift['users'] as Map?)?['name'] as String?)?.isNotEmpty == true
            ? (shift['users'] as Map)['name'] as String
            : ((shift['users'] as Map?)?['email'] as String? ?? ''))
        : null;
    final open = s.status != 'closed';
    final corrections = _events(shift).where((e) => e['corrected_at'] != null).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text('${day[0].toUpperCase()}${day.substring(1)}${who != null ? ' · $who' : ''}',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
              if (open)
                Chip(
                  label: Text(s.status == 'paused' ? l.t('wd_status_paused') : l.t('wd_status_open')),
                  visualDensity: VisualDensity.compact,
                ),
              if (s.corrected)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Chip(label: Text(l.t('wd_corrected')), visualDensity: VisualDensity.compact),
                ),
              // Solo el jefe corrige (con motivo) o cierra una jornada olvidada.
              if (_isOwner)
                PopupMenuButton<String>(
                  onSelected: (v) => v == 'close' ? _closeShift(l, shift) : _correctShift(l, shift),
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'correct', child: Text(l.t('wd_correct'))),
                    if (open) PopupMenuItem(value: 'close', child: Text(l.t('wd_close'))),
                  ],
                ),
            ]),
            const SizedBox(height: 4),
            Text(l.t('wd_in_out', {
              'in': hm.format(s.start),
              'out': s.end != null ? hm.format(s.end!) : '—',
            })),
            for (final p in s.pauses)
              Text(l.t('wd_pause_line', {
                'from': hm.format(p.from),
                'to': p.to != null ? hm.format(p.to!) : '…',
                'len': fmtWorked(p.length(DateTime.now())),
              }), style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 4),
            Text(
              [
                l.t('wd_worked', {'worked': fmtWorked(s.worked())}),
                if (s.km != null) l.t('wd_km', {'km': '${s.km}', 'from': '${s.startKm}', 'to': '${s.endKm}'}),
              ].join(' · '),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            // Rastro de las correcciones (quién no hace falta: siempre es el jefe).
            for (final e in corrections)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  l.t('wd_correction_line', {
                    'what': l.t('wd_kind_${e['kind']}'),
                    'from': e['original_at'] != null
                        ? hm.format(workdayWall('${e['original_at']}', e['utc_offset_min']))
                        : '—',
                    'to': hm.format(workdayWall('${e['at']}', e['utc_offset_min'])),
                    'reason': '${e['correction_reason'] ?? ''}',
                  }),
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade900),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // Pide hora (mismo día) y, si aplica, km + MOTIVO obligatorio.
  Future<({DateTime wall, int? km, String reason})?> _askCorrection(
      AppLocalizations l, {required String title, required DateTime initial, int? km, bool withKm = false}) async {
    var time = TimeOfDay.fromDateTime(initial);
    final kmCtrl = TextEditingController(text: km?.toString() ?? '');
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.schedule),
                label: Text('${DateFormat('d MMM', 'es').format(initial)} · ${time.format(ctx)}'),
                onPressed: () async {
                  final t = await showTimePicker(context: ctx, initialTime: time);
                  if (t != null) setLocal(() => time = t);
                },
              ),
              if (withKm) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: kmCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: l.t('dh_km_now'), suffixText: 'km'),
                ),
              ],
              const SizedBox(height: 8),
              TextField(
                controller: reasonCtrl,
                autofocus: true,
                maxLines: 2,
                decoration: InputDecoration(labelText: l.t('wd_reason'), helperText: l.t('wd_reason_help'), helperMaxLines: 3),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('save'))),
          ],
        ),
      ),
    );
    if (ok != true) return null;
    final reason = reasonCtrl.text.trim();
    if (reason.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('wd_reason_required'))));
      return null;
    }
    return (
      wall: DateTime(initial.year, initial.month, initial.day, time.hour, time.minute),
      km: int.tryParse(kmCtrl.text.trim()),
      reason: reason,
    );
  }

  // Corregir una pulsación: se elige cuál y se cambia la hora (y km en entrada/salida).
  Future<void> _correctShift(AppLocalizations l, Map<String, dynamic> shift) async {
    final hm = DateFormat('HH:mm');
    final evs = _events(shift);
    final ev = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(title: Text(l.t('wd_correct_pick'), style: const TextStyle(fontWeight: FontWeight.bold))),
          for (final e in evs)
            ListTile(
              leading: const Icon(Icons.edit_calendar),
              title: Text('${l.t('wd_kind_${e['kind']}')} · ${hm.format(workdayWall('${e['at']}', e['utc_offset_min']))}'
                  '${e['km'] != null ? ' · ${e['km']} km' : ''}'),
              onTap: () => Navigator.pop(ctx, e),
            ),
        ]),
      ),
    );
    if (ev == null || !mounted) return;
    final off = (ev['utc_offset_min'] as num?)?.toInt();
    final current = workdayWall('${ev['at']}', off);
    final withKm = ev['kind'] == 'start' || ev['kind'] == 'end';
    final r = await _askCorrection(l,
        title: '${l.t('wd_correct')}: ${l.t('wd_kind_${ev['kind']}')}',
        initial: current, km: (ev['km'] as num?)?.toInt(), withKm: withKm);
    if (r == null) return;
    try {
      final utc = off != null ? wallToUtc(r.wall, off) : r.wall.toUtc();
      await _service.workdayCorrect(ev['id'] as String, utc, km: withKm ? r.km : null, reason: r.reason);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('wd_corrected_ok'))));
      _reload();
    } catch (e) {
      if (mounted) _showRpcError(l, e);
    }
  }

  // Cerrar una jornada que el conductor dejó abierta.
  Future<void> _closeShift(AppLocalizations l, Map<String, dynamic> shift) async {
    final off = (shift['utc_offset_min'] as num?)?.toInt();
    final now = DateTime.now();
    final r = await _askCorrection(l, title: l.t('wd_close'), initial: now, withKm: true);
    if (r == null) return;
    try {
      final utc = off != null ? wallToUtc(r.wall, off) : r.wall.toUtc();
      await _service.workdayClose(shift['id'] as String, utc, km: r.km, reason: r.reason);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('wd_corrected_ok'))));
      _reload();
    } catch (e) {
      if (mounted) _showRpcError(l, e);
    }
  }

  void _showRpcError(AppLocalizations l, Object e) {
    final s = '$e';
    final key = s.contains('workday_order')
        ? 'wd_err_order'
        : s.contains('workday_future')
            ? 'wd_err_future'
            : s.contains('workday_reason_required')
                ? 'wd_reason_required'
                : null;
    if (key != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t(key))));
    } else {
      showError(context, e, screen: 'WorkdayLog');
    }
  }
}
