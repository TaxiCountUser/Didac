import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import '../util/error_ui.dart';
import '../widgets/agenda_tile.dart';
import 'agenda_input_screen.dart';

/// Histórico y búsqueda de la agenda. Permite ver los servicios PASADOS y los
/// PRÓXIMOS (incluidos los muy lejanos), buscar por empresa/cliente/ruta en
/// todas las fechas, y filtrar por una FECHA concreta. Los servicios nunca se
/// borran: aquí se recuperan todos.
class AgendaHistoryScreen extends StatefulWidget {
  final Profile profile;
  const AgendaHistoryScreen({super.key, required this.profile});

  @override
  State<AgendaHistoryScreen> createState() => _AgendaHistoryScreenState();
}

class _AgendaHistoryScreenState extends State<AgendaHistoryScreen> {
  final _service = DataService();
  final _searchCtrl = TextEditingController();
  String _query = '';
  DateTime? _pickedDay; // filtro por fecha concreta (prioritario)
  int _segment = 0; // 0 = pasados, 1 = próximos (solo sin búsqueda ni fecha)
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  bool _matches(Map<String, dynamic> e, String q) {
    for (final k in const ['name', 'pickup', 'destination', 'contact']) {
      final v = (e[k] as String?)?.toLowerCase() ?? '';
      if (v.contains(q)) return true;
    }
    return false;
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final day = _pickedDay;
    if (day != null) {
      final rows = await _service.listAgendaByDate(day);
      final q = _query.trim().toLowerCase();
      if (q.isEmpty) return rows;
      return rows.where((e) => _matches(e, q)).toList();
    }
    if (_query.trim().isNotEmpty) return _service.searchAgenda(_query);
    return _segment == 0 ? _service.listAgendaHistory() : _service.listAgenda();
  }

  void _reload() => setState(() => _future = _load());

  void _onSearchChanged(String q) {
    setState(() {
      if (q.trim().isEmpty && _query.isNotEmpty) {
        _query = '';
        _future = _load();
      }
    });
  }

  void _runSearch(String q) => setState(() {
        _query = q;
        _future = _load();
      });

  void _setSegment(int s) {
    if (s == _segment) return;
    setState(() {
      _segment = s;
      _future = _load();
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _pickedDay ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 5, 12, 31),
    );
    if (picked != null && mounted) {
      setState(() {
        _pickedDay = picked;
        _future = _load();
      });
    }
  }

  void _clearDate() => setState(() {
        _pickedDay = null;
        _future = _load();
      });

  Future<void> _edit(Map<String, dynamic> ev) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AgendaInputScreen(
            profile: widget.profile, editId: ev['id'] as String, initial: ev),
      ),
    );
    if (changed == true) _reload();
  }

  Future<void> _delete(Map<String, dynamic> ev) async {
    final l = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('ag_delete_q')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('ag_delete'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _service.deleteAgendaEvent(ev['id'] as String);
      _reload();
    } catch (e) {
      if (mounted) showError(context, e, screen: 'Agenda');
    }
  }

  Future<void> _toggleDone(Map<String, dynamic> ev) async {
    final done = ev['status'] == 'done';
    try {
      await _service.setAgendaStatus(ev['id'] as String, done ? 'pending' : 'done');
      _reload();
    } catch (e) {
      if (mounted) showError(context, e, screen: 'Agenda');
    }
  }

  String _dmy(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final searching = _query.trim().isNotEmpty;
    final byDate = _pickedDay != null;
    return Scaffold(
      appBar: AppBar(title: Text(l.t('ag_history_title'))),
      body: Column(
        children: [
          // Buscador por texto + botón de fecha.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    textInputAction: TextInputAction.search,
                    onSubmitted: _runSearch,
                    onChanged: _onSearchChanged,
                    decoration: InputDecoration(
                      hintText: l.t('ag_search_hint'),
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchCtrl.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _searchCtrl.clear();
                                _runSearch('');
                              },
                            ),
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  tooltip: l.t('ag_pick_date'),
                  onPressed: _pickDate,
                  icon: const Icon(Icons.event),
                ),
              ],
            ),
          ),
          // Chip con la fecha elegida (si hay) para poder quitarla.
          if (byDate)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: InputChip(
                  avatar: const Icon(Icons.event, size: 18),
                  label: Text(_dmy(_pickedDay!)),
                  onDeleted: _clearDate,
                ),
              ),
            ),
          // Segmento Pasados / Próximos (solo si no filtramos por texto ni fecha).
          if (!searching && !byDate)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: SegmentedButton<int>(
                segments: [
                  ButtonSegment(value: 0, label: Text(l.t('ag_seg_past')), icon: const Icon(Icons.history)),
                  ButtonSegment(value: 1, label: Text(l.t('ag_seg_upcoming')), icon: const Icon(Icons.event)),
                ],
                selected: {_segment},
                onSelectionChanged: (s) => _setSegment(s.first),
                showSelectedIcon: false,
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => _reload(),
              child: FutureBuilder<List<Map<String, dynamic>>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return errorRetry(context, _reload);
                  }
                  final items = snap.data ?? const [];
                  if (items.isEmpty) {
                    final msg = byDate
                        ? l.t('ag_no_on_date')
                        : searching
                            ? l.t('ag_no_results')
                            : (_segment == 0 ? l.t('ag_no_past') : l.t('ag_empty'));
                    return ListView(children: [
                      const SizedBox(height: 100),
                      Icon(Icons.calendar_month,
                          size: 48, color: Theme.of(context).colorScheme.outline),
                      const SizedBox(height: 12),
                      Center(child: Text(msg)),
                    ]);
                  }
                  return ListView(
                    children: buildAgendaGrouped(context, items, tile: (ev, when) {
                      return AgendaTile(
                        ev: ev,
                        when: when,
                        onToggleDone: () => _toggleDone(ev),
                        onEdit: () => _edit(ev),
                        onDelete: () => _delete(ev),
                      );
                    }),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
