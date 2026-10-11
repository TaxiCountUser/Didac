import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import '../util/error_ui.dart';
import '../widgets/agenda_tile.dart';
import 'agenda_input_screen.dart';

/// Histórico y búsqueda de la agenda. Permite ver los servicios PASADOS y los
/// PRÓXIMOS (incluidos los muy lejanos) y buscar por empresa/cliente/ruta en
/// todas las fechas. Los servicios nunca se borran: aquí se recuperan todos.
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
  int _segment = 0; // 0 = pasados, 1 = próximos (solo cuando no hay búsqueda)
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

  Future<List<Map<String, dynamic>>> _load() {
    if (_query.trim().isNotEmpty) return _service.searchAgenda(_query);
    return _segment == 0 ? _service.listAgendaHistory() : _service.listAgenda();
  }

  void _reload() => setState(() => _future = _load());

  void _onSearchChanged(String q) {
    // setState en cada tecla para refrescar el icono de limpiar; al vaciar la
    // caja volvemos a la vista por segmento (la búsqueda se lanza al pulsar Intro).
    setState(() {
      if (q.trim().isEmpty && _query.isNotEmpty) {
        _query = '';
        _future = _load();
      }
    });
  }

  void _runSearch(String q) {
    setState(() {
      _query = q;
      _future = _load();
    });
  }

  void _setSegment(int s) {
    if (s == _segment) return;
    setState(() {
      _segment = s;
      _future = _load();
    });
  }

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

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final searching = _query.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: Text(l.t('ag_history_title'))),
      body: Column(
        children: [
          // Buscador.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
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
          // Segmento Pasados / Próximos (solo si no estamos buscando).
          if (!searching)
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
                    final msg = searching
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
