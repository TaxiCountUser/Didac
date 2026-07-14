import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import 'fleet_chat_screen.dart';

/// Panel del jefe: lista de sus conductores. Cada uno abre un chat 1:1.
/// El conductor no usa esta pantalla (tiene un único chat con su jefe).
class FleetChatsScreen extends StatefulWidget {
  final Profile profile;

  /// true cuando se abre como pantalla propia (desde Ajustes): muestra AppBar.
  final bool standalone;
  const FleetChatsScreen({super.key, required this.profile, this.standalone = false});

  @override
  State<FleetChatsScreen> createState() => _FleetChatsScreenState();
}

class _FleetChatsScreenState extends State<FleetChatsScreen> {
  final _service = DataService();
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => setState(() => _future = _service.listDrivers());

  String _driverName(Map<String, dynamic> d) {
    final name = (d['display_name'] ?? d['name'] ?? '').toString().trim();
    if (name.isNotEmpty) return name;
    return (d['email'] ?? '').toString();
  }

  Future<void> _openChat(Map<String, dynamic> d) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FleetChatScreen(
        profile: widget.profile,
        driverId: d['id'] as String,
        title: _driverName(d),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: widget.standalone ? AppBar(title: Text(l.t('nav_messages'))) : null,
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('${l.t('error')}: ${snap.error}'));
          }
          final drivers = snap.data ?? [];
          if (drivers.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(l.t('fleet_no_drivers'), textAlign: TextAlign.center),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView.separated(
              itemCount: drivers.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final d = drivers[i];
                final name = _driverName(d);
                return ListTile(
                  leading: CircleAvatar(
                    child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?'),
                  ),
                  title: Text(name),
                  trailing: const Icon(Icons.chat_bubble_outline),
                  onTap: () => _openChat(d),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
