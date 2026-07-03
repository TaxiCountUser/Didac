import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import '../util/format.dart';
import 'incident_chat_screen.dart';

/// Incidencias / mensajes al jefe.
///  - Conductor: ve las suyas y puede escribir una nota al jefe.
///  - Owner: ve las de toda la flota (con autor) y puede marcarlas resueltas.
class IncidentsScreen extends StatefulWidget {
  final Profile profile;
  /// true cuando se abre como pantalla propia (desde Ajustes): muestra AppBar
  /// con flecha de volver. false cuando es una pestaña del panel del jefe.
  final bool standalone;
  const IncidentsScreen({super.key, required this.profile, this.standalone = false});

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

  // El jefe ve todas las incidencias de su flota (notas y tickets de soporte
  // chófer<->admin). El conductor aquí SOLO ve sus notas al jefe: sus reportes
  // de error ('app') viven en "Informar de un error" (TicketsScreen), para que
  // no se dupliquen en "Mensaje al jefe". (RLS acota por tenant/autor.)
  void _reload() => setState(() => _future =
      _service.listIncidents(kind: widget.profile.isOwner ? null : 'nota'));

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

  Future<bool> _confirmDelete() async {
    final l = context.l10n;
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l.t('inc_delete')),
            content: Text(l.t('inc_delete_confirm')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('inc_delete'))),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _delete(String id) async {
    try {
      // Soft-delete: se quita del panel de la empresa, pero se conserva para el
      // administrador de la plataforma (por si hay una denuncia/problema futuro).
      await _service.hideIncident(id);
      _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _openChat(Map<String, dynamic> incident) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => IncidentChatScreen(profile: widget.profile, incident: incident),
    ));
    _reload(); // por si se resolvió o se respondió
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final isOwner = widget.profile.isOwner;
    return Scaffold(
      appBar: widget.standalone
          ? AppBar(title: Text(isOwner ? l.t('set_incidents_owner') : l.t('set_incidents_driver')))
          : null,
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
              itemBuilder: (context, i) {
                final it = items[i];
                final tile = _tile(it, isOwner);
                if (!isOwner) return tile; // solo el jefe puede borrar
                return Dismissible(
                  key: ValueKey(it['id']),
                  direction: DismissDirection.endToStart,
                  confirmDismiss: (_) => _confirmDelete(),
                  onDismissed: (_) => _delete(it['id'] as String),
                  background: Container(
                    color: Colors.red,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  child: tile,
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _tile(Map<String, dynamic> it, bool isOwner) {
    final l = context.l10n;
    final kind = it['kind'] as String? ?? 'nota';
    final isApp = kind == 'app'; // ticket de soporte (chófer <-> admin)
    final resolved = it['status'] == 'resuelta';
    final created = parseCreatedAt(it['created_at']);
    final sub = <String>[
      if (isOwner) driverName(it),
      fmtDateTime(created),
      if (isApp) l.t('inc_admin_chat'),
    ].join(' · ');

    return ListTile(
      onTap: () => _openChat(it),
      // Símbolo distinto: soporte (chófer<->admin) vs nota (chófer<->jefe).
      leading: Icon(
        isApp ? Icons.support_agent : Icons.chat_bubble_outline,
        color: resolved ? Colors.grey : (isApp ? Colors.deepPurple : Colors.blueGrey),
      ),
      title: Text(
        it['body'] as String? ?? '',
        style: TextStyle(
          decoration: resolved ? TextDecoration.lineThrough : null,
          color: resolved ? Colors.grey : null,
        ),
      ),
      subtitle: Text(sub),
      // Las de soporte (app) las cierra el admin, no el jefe.
      trailing: resolved
          ? Chip(label: Text(l.t('inc_resolved')), visualDensity: VisualDensity.compact)
          : (isOwner && !isApp
              ? TextButton(onPressed: () => _resolve(it['id'] as String), child: Text(l.t('inc_resolve')))
              : Chip(label: Text(l.t('inc_open')), visualDensity: VisualDensity.compact)),
    );
  }
}
