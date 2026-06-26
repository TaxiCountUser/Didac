import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import '../util/format.dart';
import 'incident_chat_screen.dart';

/// Tickets de soporte del usuario: reportar un fallo de la app y chatear con la
/// administración. Lista tus tickets (abiertos y cerrados) y permite crear uno
/// nuevo; cada ticket es un chat con el admin.
class TicketsScreen extends StatefulWidget {
  final Profile profile;
  const TicketsScreen({super.key, required this.profile});

  @override
  State<TicketsScreen> createState() => _TicketsScreenState();
}

class _TicketsScreenState extends State<TicketsScreen> {
  final _service = DataService();
  late Future<List<Map<String, dynamic>>> _future = _service.listMyTickets();

  void _reload() => setState(() => _future = _service.listMyTickets());

  Future<void> _openChat(Map<String, dynamic> incident) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => IncidentChatScreen(profile: widget.profile, incident: incident),
    ));
    _reload();
  }

  Future<void> _newTicket() async {
    final l = context.l10n;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('tk_new')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 4,
          decoration: InputDecoration(hintText: l.t('tk_hint'), border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('tk_create'))),
        ],
      ),
    );
    if (ok != true || ctrl.text.trim().isEmpty) return;
    try {
      final row = await _service.createTicket(widget.profile.tenantId, ctrl.text.trim());
      _reload();
      if (row != null && mounted) await _openChat(row);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${l.t('error')}: ${e.toString().replaceFirst('Exception: ', '')}')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l.t('tk_title'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newTicket,
        icon: const Icon(Icons.add),
        label: Text(l.t('tk_new')),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('${l.t('error')}: ${snap.error}'));
          }
          final tickets = snap.data ?? [];
          if (tickets.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(l.t('tk_empty'), textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey)),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView.separated(
              itemCount: tickets.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final t = tickets[i];
                final resolved = t['status'] == 'resuelta';
                return ListTile(
                  leading: Icon(Icons.support_agent,
                      color: resolved ? Colors.grey : Colors.deepPurple),
                  title: Text(t['body'] as String? ?? '',
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          decoration: resolved ? TextDecoration.lineThrough : null,
                          color: resolved ? Colors.grey : null)),
                  subtitle: Text(fmtDateTime(parseCreatedAt(t['created_at']))),
                  trailing: Chip(
                    label: Text(resolved ? l.t('tk_closed') : l.t('tk_open')),
                    visualDensity: VisualDensity.compact,
                    backgroundColor: resolved ? Colors.grey.shade300 : Colors.green.shade100,
                  ),
                  onTap: () => _openChat(t),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
