import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import '../util/format.dart';

/// Incidencias / mensajes al jefe.
///  - Conductor: ve las suyas y puede escribir una nota al jefe.
///  - Owner: ve las de toda la flota (con autor) y puede marcarlas resueltas.
class IncidentsScreen extends StatefulWidget {
  final Profile profile;
  const IncidentsScreen({super.key, required this.profile});

  @override
  State<IncidentsScreen> createState() => _IncidentsScreenState();
}

class _IncidentsScreenState extends State<IncidentsScreen> {
  final _service = DataService();
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => setState(() => _future = _service.listIncidents());

  Future<void> _addNote() async {
    final l = context.l10n;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('inc_to_boss')),
        content: TextField(
          key: const Key('incident_body'),
          controller: ctrl,
          autofocus: true,
          maxLines: 4,
          decoration: InputDecoration(hintText: l.t('inc_hint'), border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('send'))),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      try {
        await _service.addIncident(
          tenantId: widget.profile.tenantId,
          kind: 'nota',
          body: ctrl.text.trim(),
        );
        _reload();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('inc_sent'))));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l.t('error')}: $e')));
        }
      }
    }
  }

  Future<void> _resolve(String id) async {
    try {
      await _service.resolveIncident(id);
      _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final isOwner = widget.profile.isOwner;
    return Scaffold(
      floatingActionButton: isOwner
          ? null
          : FloatingActionButton.extended(
              key: const Key('add_incident_fab'),
              onPressed: _addNote,
              icon: const Icon(Icons.edit),
              label: Text(l.t('inc_to_boss')),
            ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          final items = snap.data ?? [];
          if (items.isEmpty) {
            return Center(
              child: Text(isOwner ? l.t('inc_none_owner') : l.t('inc_none_driver'),
                  textAlign: TextAlign.center),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) => _tile(items[i], isOwner),
            ),
          );
        },
      ),
    );
  }

  Widget _tile(Map<String, dynamic> it, bool isOwner) {
    final l = context.l10n;
    final kind = it['kind'] as String? ?? 'nota';
    final resolved = it['status'] == 'resuelta';
    final created = parseCreatedAt(it['created_at']);
    final sub = <String>[
      if (isOwner) driverName(it),
      fmtDateTime(created),
      if (kind == 'app') l.t('inc_app_bug'),
    ].join(' · ');

    return ListTile(
      leading: Icon(
        kind == 'app' ? Icons.bug_report : Icons.chat_bubble_outline,
        color: resolved ? Colors.grey : (kind == 'app' ? Colors.deepOrange : Colors.blueGrey),
      ),
      title: Text(
        it['body'] as String? ?? '',
        style: TextStyle(
          decoration: resolved ? TextDecoration.lineThrough : null,
          color: resolved ? Colors.grey : null,
        ),
      ),
      subtitle: Text(sub),
      trailing: resolved
          ? Chip(label: Text(l.t('inc_resolved')), visualDensity: VisualDensity.compact)
          : (isOwner
              ? TextButton(onPressed: () => _resolve(it['id'] as String), child: Text(l.t('inc_resolve')))
              : Chip(label: Text(l.t('inc_open')), visualDensity: VisualDensity.compact)),
    );
  }
}
