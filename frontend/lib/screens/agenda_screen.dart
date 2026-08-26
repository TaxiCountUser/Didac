import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import '../util/error_ui.dart';
import 'agenda_input_screen.dart';

/// AGENDA compartida de la empresa (opción oculta y de pago, Fase 1). Lista de
/// servicios programados, agrupados por día. La ve y gestiona toda la empresa.
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
    return Scaffold(
      appBar: AppBar(title: Text(l.t('ag_list_title'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: Text(l.t('ag_add')),
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
            return ListView(children: _grouped(items));
          },
        ),
      ),
    );
  }

  // Construye la lista con cabeceras de día.
  List<Widget> _grouped(List<Map<String, dynamic>> items) {
    final l = context.l10n;
    final out = <Widget>[];
    String? lastDay;
    for (final ev in items) {
      final when = DateTime.tryParse('${ev['scheduled_at']}')?.toLocal();
      final dayKey = when == null ? '' : '${when.year}-${when.month}-${when.day}';
      if (dayKey != lastDay) {
        lastDay = dayKey;
        out.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Text(_dayLabel(when),
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ));
      }
      out.add(_tile(ev, when));
    }
    out.add(const SizedBox(height: 80));
    if (out.isEmpty) out.add(Center(child: Text(l.t('ag_empty'))));
    return out;
  }

  Widget _tile(Map<String, dynamic> ev, DateTime? when) {
    final l = context.l10n;
    final done = ev['status'] == 'done';
    final hhmm = when == null
        ? '--:--'
        : '${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}';
    final name = (ev['name'] as String?)?.trim() ?? '';
    final pickup = (ev['pickup'] as String?)?.trim() ?? '';
    final dest = (ev['destination'] as String?)?.trim() ?? '';
    final contact = (ev['contact'] as String?)?.trim() ?? '';
    final note = (ev['note'] as String?)?.trim() ?? '';
    final price = ev['price_approx'];
    final author = (ev['users'] as Map?)?['name'] ?? (ev['users'] as Map?)?['email'] ?? '';
    final route = (pickup.isNotEmpty || dest.isNotEmpty)
        ? '${pickup.isEmpty ? '—' : pickup} → ${dest.isEmpty ? '—' : dest}'
        : '';
    final sub = <String>[
      if (contact.isNotEmpty) '📞 $contact',
      if (author.toString().isNotEmpty) '${l.t('ag_by')}: $author',
      if (note.isNotEmpty) note,
    ].join(' · ');

    return ListTile(
      leading: IconButton(
        tooltip: done ? l.t('ag_mark_pending') : l.t('ag_mark_done'),
        icon: Icon(done ? Icons.check_circle : Icons.radio_button_unchecked,
            color: done ? Colors.green : null),
        onPressed: () => _toggleDone(ev),
      ),
      title: Text(
        [hhmm, if (name.isNotEmpty) name, if (route.isNotEmpty) route].join(' · '),
        style: TextStyle(
          decoration: done ? TextDecoration.lineThrough : null,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: sub.isEmpty ? null : Text(sub, style: const TextStyle(fontSize: 12)),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (price != null)
          Text('${(price as num).toStringAsFixed(2)} €',
              style: const TextStyle(fontWeight: FontWeight.w600)),
        PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'edit') _edit(ev);
            if (v == 'delete') _delete(ev);
          },
          itemBuilder: (ctx) => [
            PopupMenuItem(value: 'edit', child: Text(l.t('edit'))),
            PopupMenuItem(value: 'delete', child: Text(l.t('ag_delete'))),
          ],
        ),
      ]),
      onTap: () => _edit(ev),
    );
  }

  String _dayLabel(DateTime? d) {
    if (d == null) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = day.difference(today).inDays;
    final l = context.l10n;
    if (diff == 0) return l.t('ag_today');
    if (diff == 1) return l.t('ag_tomorrow');
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }
}
