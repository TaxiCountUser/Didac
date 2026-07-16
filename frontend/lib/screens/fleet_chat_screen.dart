import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import '../util/format.dart';
import '../widgets/dictate_button.dart';

/// Chat de flota (jefe <-> conductor). Un hilo por conductor.
///  - Owner: [driverId] es el conductor con el que chatea; [title] su nombre.
///  - Conductor: [driverId] es su propio id; [title] "Mensaje al jefe".
/// No hay estado "resuelta": es una conversación abierta y permanente.
class FleetChatScreen extends StatefulWidget {
  final Profile profile;
  final String driverId;
  final String title;
  const FleetChatScreen({
    super.key,
    required this.profile,
    required this.driverId,
    required this.title,
  });

  @override
  State<FleetChatScreen> createState() => _FleetChatScreenState();
}

class _FleetChatScreenState extends State<FleetChatScreen> {
  final _service = DataService();
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  late Future<List<Map<String, dynamic>>> _future;
  RealtimeChannel? _channel;
  bool _sending = false;
  String? _bossName; // nombre real del jefe (para el conductor)

  @override
  void initState() {
    super.initState();
    _reload();
    // El conductor ve el NOMBRE del jefe (no puede leer su fila por RLS).
    if (!widget.profile.isOwner) {
      _service.fleetBossName().then((n) {
        if (mounted && n != null) setState(() => _bossName = n);
      });
    }
    // Refresco en vivo cuando llega/envía un mensaje en este hilo.
    _channel = _service.fleetThreadChannel(widget.driverId, () {
      if (mounted) _reload();
    });
  }

  @override
  void dispose() {
    if (_channel != null) _service.client.removeChannel(_channel!);
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _reload() =>
      setState(() => _future = _service.listFleetMessages(widget.driverId));

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await _service.sendFleetMessage(
        tenantId: widget.profile.tenantId,
        driverId: widget.driverId,
        body: text,
      );
      _ctrl.clear();
      _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${context.l10n.t('error')}: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _appendDictated(String text) {
    final cur = _ctrl.text.trim();
    _ctrl.text = cur.isEmpty ? text : '$cur $text';
    _ctrl.selection = TextSelection.fromPosition(TextPosition(offset: _ctrl.text.length));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.profile.isOwner ? widget.title : (_bossName ?? widget.title)),
      ),
      body: Column(
        children: [
          Expanded(child: _messages(l)),
          _composer(l),
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
          return Center(child: Text('${l.t('error')}: ${snap.error}'));
        }
        final msgs = snap.data ?? [];
        if (msgs.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l.t('fleet_empty'),
                  textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
            ),
          );
        }
        final myId = widget.profile.id;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
        return ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.all(12),
          itemCount: msgs.length,
          itemBuilder: (context, i) {
            final m = msgs[i];
            final mine = m['sender_id'] == myId;
            return Align(
              alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                constraints: const BoxConstraints(maxWidth: 320),
                decoration: BoxDecoration(
                  color: mine ? Colors.amber.shade200 : Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!mine)
                      Text(_otherLabel(l),
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

  // Etiqueta del OTRO interlocutor (los mensajes propios no la muestran). Se
  // deduce del rol de quien mira, sin depender de un join: si mira el conductor,
  // el otro es su jefe; si mira el jefe, el otro es ese conductor (su nombre es
  // el título del chat).
  String _otherLabel(AppLocalizations l) {
    if (widget.profile.isOwner) {
      return widget.title.trim().isEmpty ? l.t('fleet_sender_driver') : widget.title;
    }
    return _bossName ?? l.t('fleet_sender_boss');
  }

  Widget _composer(AppLocalizations l) {
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
                  hintText: l.t('fleet_write_msg'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            DictateButton(onText: _appendDictated),
            const SizedBox(width: 4),
            _sending
                ? const Padding(
                    padding: EdgeInsets.all(8),
                    child: SizedBox(
                        width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
                : IconButton.filled(onPressed: _send, icon: const Icon(Icons.send)),
          ],
        ),
      ),
    );
  }
}
