import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import '../util/error_ui.dart';
import '../widgets/agenda_tile.dart';
import 'agenda_input_screen.dart';
import 'agenda_history_screen.dart';
import 'transaction_input_screen.dart';

/// AGENDA compartida de la empresa (opción oculta y de pago, Fase 1). Lista de
/// servicios PRÓXIMOS, agrupados por día. El histórico (pasados) y la búsqueda
/// por empresa están en [AgendaHistoryScreen] (botón de calendario).
class AgendaScreen extends StatefulWidget {
  final Profile profile;
  const AgendaScreen({super.key, required this.profile});

  @override
  State<AgendaScreen> createState() => _AgendaScreenState();
}

class _AgendaScreenState extends State<AgendaScreen> {
  final _service = DataService();
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _service.listAgenda();
  }

  void _reload() => setState(() => _future = _service.listAgenda());

  Future<void> _add() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => AgendaInputScreen(profile: widget.profile)),
    );
    if (changed == true) _reload();
  }

  Future<void> _openHistory() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => AgendaHistoryScreen(profile: widget.profile)),
    );
    // Al volver, refrescamos por si se editó/borró algo que afecta a los próximos.
    if (mounted) _reload();
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

  // Registra el servicio como una carrera: abre el formulario prellenado y, si
  // se guarda, marca el servicio como hecho para no duplicarlo.
  Future<void> _register(Map<String, dynamic> ev) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TransactionInputScreen(
            profile: widget.profile, initial: agendaToTripInitial(ev), popWithResult: true),
      ),
    );
    if (saved == true) {
      try {
        await _service.setAgendaStatus(ev['id'] as String, 'done');
      } catch (_) {/* el registro ya se guardó; marcar hecho es best-effort */}
      if (mounted) _reload();
    }
  }

  // Asignar el servicio a un conductor (solo el titular).
  Future<void> _assign(Map<String, dynamic> ev) async {
    final changed = await showAssignAgendaSheet(context, _service, ev);
    if (changed && mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l.t('ag_list_title'))),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'agendaHistory',
            tooltip: l.t('ag_history'),
            onPressed: _openHistory,
            child: const Icon(Icons.calendar_month),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'agendaAdd',
            onPressed: _add,
            icon: const Icon(Icons.add),
            label: Text(l.t('ag_add')),
          ),
        ],
      ),
      body: RefreshIndicator(
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
              return ListView(children: [
                const SizedBox(height: 120),
                Icon(Icons.calendar_month, size: 48, color: Theme.of(context).colorScheme.outline),
                const SizedBox(height: 12),
                Center(child: Text(l.t('ag_empty'))),
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
                  onRegister: () => _register(ev),
                  onAssign: () => _assign(ev),
                  canAssign: widget.profile.isOwner,
                );
              }),
            );
          },
        ),
      ),
    );
  }
}
