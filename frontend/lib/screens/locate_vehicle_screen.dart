import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import '../util/format.dart';

/// Localizar vehículo (Owner): última ubicación conocida de cada conductor,
/// con opción de abrirla en el mapa. Versión básica (no tiempo real).
class LocateVehicleScreen extends StatefulWidget {
  final Profile profile;
  const LocateVehicleScreen({super.key, required this.profile});

  @override
  State<LocateVehicleScreen> createState() => _LocateVehicleScreenState();
}

class _LocateVehicleScreenState extends State<LocateVehicleScreen> {
  final _service = DataService();
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => setState(() => _future = _service.listDriverLocations());

  Future<void> _openMap(double lat, double lng) async {
    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.t('sub_no_browser'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.t('set_locate_vehicle')),
        actions: [
          IconButton(onPressed: _reload, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return Center(child: Text('${l.t('error')}: ${snap.error}'));
          final items = snap.data ?? [];
          if (items.isEmpty) {
            return Center(child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l.t('loc_none'), textAlign: TextAlign.center),
            ));
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final it = items[i];
                final lat = (it['lat'] as num).toDouble();
                final lng = (it['lng'] as num).toDouble();
                final acc = it['accuracy'] as num?;
                final when = fmtDateTime(parseCreatedAt(it['updated_at']));
                final accText = acc == null ? '' : ' · ±${acc.round()} m ${l.t('loc_accuracy')}';
                return ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.location_on)),
                  title: Text(driverName(it)),
                  subtitle: Text('$when$accText'),
                  trailing: FilledButton.icon(
                    onPressed: () => _openMap(lat, lng),
                    icon: const Icon(Icons.map),
                    label: Text(l.t('loc_open_map')),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
