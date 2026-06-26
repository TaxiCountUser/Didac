import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import '../util/format.dart';

/// Chat de una incidencia desde el panel de administración: el admin habla con
/// el cliente (autor de la incidencia) hasta que la cierra. Va por endpoints de
/// admin (service_role) para poder acceder a cualquier empresa.
class AdminIncidentChatScreen extends StatefulWidget {
  final Map<String, dynamic> incident;
  const AdminIncidentChatScreen({super.key, required this.incident});

  @override
  State<AdminIncidentChatScreen> createState() => _AdminIncidentChatScreenState();
}

class _AdminIncidentChatScreenState extends State<AdminIncidentChatScreen> {
  final _service = DataService();
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  late Future<List<Map<String, dynamic>>> _future;
  late bool _resolved = widget.incident['status'] == 'resuelta';
  bool _sending = false;
  bool _changed = false; // para refrescar la lista al volver

  String get _id => widget.incident['id'] as String;
  String? get _myId => Supabase.instance.client.auth.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _reload() => setState(() => _future = _service.adminIncidentMessages(_id));

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await _service.adminSendIncidentMessage(_id, text);
      _ctrl.clear();
      _changed = true;
      _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${context.l10n.t('error')}: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _toggleResolved() async {
    final newStatus = _resolved ? 'abierta' : 'resuelta';
    try {
      await _service.adminSetIncidentStatus(_id, newStatus);
      if (mounted) {
        setState(() {
          _resolved = !_resolved;
          _changed = true;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${context.l10n.t('error')}: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && _changed) {
          // (el padre recarga en su propio flujo)
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.t('inc_chat_title')),
          actions: [
            TextButton(
              onPressed: _toggleResolved,
              child: Text(_resolved ? l.t('admin_reopen') : l.t('inc_resolve'),
                  style: const TextStyle(color: Colors.white)),
            ),
          ],
        ),
        body: Column(
          children: [
            _header(l),
            const Divider(height: 1),
            Expanded(child: _messages(l)),
            _composer(l),
          ],
        ),
      ),
    );
  }

  Widget _header(AppLocalizations l) {
    final kind = widget.incident['kind'] as String? ?? 'nota';
    final company = ((widget.incident['tenants'] as Map?)?['name'] as String?) ?? '';
    final author = ((widget.incident['users'] as Map?)?['email'] as String?) ?? '';
    return Container(
      width: double.infinity,
      color: Colors.amber.shade50,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(kind == 'app' ? Icons.bug_report : Icons.report_problem,
                  size: 18, color: Colors.deepOrange),
              const SizedBox(width: 6),
              Expanded(
                child: Text(widget.incident['body'] as String? ?? '',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          if (company.isNotEmpty || author.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text([company, author].where((e) => e.isNotEmpty).join(' · '),
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          if (_resolved)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Chip(
                label: Text(l.t('inc_resolved')),
                visualDensity: VisualDensity.compact,
                backgroundColor: Colors.grey.shade300,
              ),
            ),
        ],
      ),
    );
  }

  Widget _messages(AppLocalizations l) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text('${l.t('error')}: ${snap.error.toString().replaceFirst('Exception: ', '')}'));
        }
        final msgs = snap.data ?? [];
        if (msgs.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l.t('inc_chat_empty'),
                  textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
            ),
          );
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
        return ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.all(12),
          itemCount: msgs.length,
          itemBuilder: (context, i) {
            final m = msgs[i];
            final mine = m['user_id'] == _myId;
            final roleLabel = mine ? l.t('role_admin') : l.t(senderRoleKey(m));
            return Align(
              alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                constraints: const BoxConstraints(maxWidth: 320),
                decoration: BoxDecoration(
                  color: mine ? Colors.deepPurple.shade100 : Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(roleLabel,
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    Text(m['body'] as String? ?? ''),
                    Text(fmtDateTime(parseCreatedAt(m['created_at'])),
                        style: const TextStyle(fontSize: 10, color: Colors.grey)),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _composer(AppLocalizations l) {
    if (_resolved) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        color: Colors.grey.shade100,
        child: Text(l.t('inc_closed'),
            textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
      );
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: l.t('inc_write_msg'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _sending
                ? const Padding(
                    padding: EdgeInsets.all(8),
                    child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
                : IconButton.filled(onPressed: _send, icon: const Icon(Icons.send)),
          ],
        ),
      ),
    );
  }
}
