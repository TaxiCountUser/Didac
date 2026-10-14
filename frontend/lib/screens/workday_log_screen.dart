import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import '../util/workday.dart';

/// Registro de jornada (mig. 093). El conductor ve SU registro (lo exige la ley);
/// el jefe / autónomo ve el de cualquiera de su empresa (selector de conductor).
/// Por día: entrada, pausas, salida, horas trabajadas y km; total del mes.
/// Nadie lo edita aquí: las correcciones las hace el jefe con motivo (fase 2).
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

  bool get _isOwner => widget.profile.isOwner;

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
      _future = _service.listShifts(
          userId: _userId, from: _month, to: DateTime(_month.year, _month.month + 1));
    });
  }

  void _moveMonth(int delta) {
    _month = DateTime(_month.year, _month.month + delta);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final monthLabel = DateFormat('MMMM yyyy', 'es').format(_month);
    return Scaffold(
      appBar: AppBar(title: Text(l.t('wd_log_title'))),
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
                return ListView(
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
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _shiftCard(AppLocalizations l, Map<String, dynamic> shift, WorkdaySummary s) {
    final hm = DateFormat('HH:mm');
    final day = DateFormat('EEEE d MMM', 'es').format(s.start);
    final who = _isOwner && _userId == null
        ? (((shift['users'] as Map?)?['name'] as String?)?.isNotEmpty == true
            ? (shift['users'] as Map)['name'] as String
            : ((shift['users'] as Map?)?['email'] as String? ?? ''))
        : null;
    final open = s.status != 'closed';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
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
          ],
        ),
      ),
    );
  }
}
