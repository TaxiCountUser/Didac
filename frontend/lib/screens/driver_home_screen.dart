import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import '../services/location_service.dart';
import '../services/push_service.dart';
import 'add_record_screen.dart';
import 'driver_transactions_screen.dart';
import 'settings_screen.dart';

/// Home del Driver: elige entre añadir un registro o ver sus transacciones.
/// Al abrir, si procede, pide los km del coche con los que empieza el día.
class DriverHomeScreen extends StatefulWidget {
  final Profile profile;

  /// [embedded] = true en modo autónomo (SoloHome): se omite la AppBar (el
  /// conmutador la aporta el contenedor) y NO se hace seguimiento GPS.
  final bool embedded;
  const DriverHomeScreen({super.key, required this.profile, this.embedded = false});

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> {
  final _service = DataService();
  StreamSubscription<Position>? _posSub;

  @override
  void initState() {
    super.initState();
    // En modo autónomo no se comparte ubicación (no hay jefe que la consulte).
    if (!widget.embedded) _startTracking();
    PushService.instance.register(widget.profile.tenantId);
  }

  @override
  void dispose() {
    _posSub?.cancel();
    super.dispose();
  }

  // Comparte la ubicación con el jefe: una vez al instante + seguimiento
  // continuo mientras la app esté abierta (best-effort, con permiso del SO).
  Future<void> _startTracking() async {
    try {
      final pos = await LocationService.currentPosition();
      if (pos != null) await _push(pos);
      final stream = await LocationService.positionStream();
      if (stream == null || !mounted) return;
      _posSub = stream.listen(_push, onError: (_) {});
    } catch (_) {/* sin ubicación: no pasa nada */}
  }

  Future<void> _push(Position pos) async {
    try {
      await _service.updateMyLocation(
        tenantId: widget.profile.tenantId,
        lat: pos.latitude,
        lng: pos.longitude,
        accuracy: pos.accuracy,
      );
    } catch (_) {}
  }

  // INICIAR jornada (botón): elige el coche del día y apunta los km de inicio.
  // El campo viene precargado con los últimos km conocidos.
  Future<void> _startDay() async {
    try {
      final vehicles = await _service.myVehicles();
      if (!mounted) return;
      if (vehicles.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.t('dh_no_vehicles'))));
        return;
      }
      await _showKmDialog(vehicles, title: context.l10n.t('dh_start_day'), barrier: true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  // Aviso de km al FINALIZAR el día (manual, desde el botón).
  Future<void> _endOfDay() async {
    try {
      final vehicles = await _service.myVehicles();
      if (!mounted) return;
      if (vehicles.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.t('dh_no_vehicles'))),
        );
        return;
      }
      final preId = await _service.todaysVehicleId(widget.profile.id);
      if (!mounted) return;
      await _showKmDialog(vehicles,
          title: context.l10n.t('dh_finish_day'), preVehicleId: preId, barrier: true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  String _vehicleLabel(Map<String, dynamic> v) {
    final plate = (v['license_plate'] as String?) ?? '';
    final model = (v['model'] as String?) ?? '';
    if (plate.isNotEmpty && model.isNotEmpty) return '$plate · $model';
    return plate.isNotEmpty ? plate : (model.isNotEmpty ? model : 'Vehículo');
  }

  // Diálogo reutilizable de km (inicio o fin de jornada).
  Future<void> _showKmDialog(
    List<Map<String, dynamic>> vehicles, {
    required String title,
    String? preVehicleId,
    bool barrier = true,
  }) async {
    final l = context.l10n;
    var vehicleId = (preVehicleId != null && vehicles.any((v) => v['id'] == preVehicleId))
        ? preVehicleId
        : vehicles.first['id'] as String;
    final kmCtrl = TextEditingController();

    Future<void> prefill(String vid) async {
      final last = await _service.lastOdometer(vid);
      kmCtrl.text = last?.toString() ?? '';
    }

    await prefill(vehicleId);
    if (!mounted) return;

    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: barrier,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (vehicles.length > 1) ...[
                DropdownButtonFormField<String>(
                  key: const Key('daily_km_vehicle'),
                  initialValue: vehicleId,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: l.t('dh_vehicle')),
                  items: [
                    for (final v in vehicles)
                      DropdownMenuItem(value: v['id'] as String, child: Text(_vehicleLabel(v))),
                  ],
                  onChanged: (val) async {
                    if (val == null) return;
                    vehicleId = val;
                    await prefill(val);
                    setLocal(() {});
                  },
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                key: const Key('daily_km_field'),
                controller: kmCtrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: l.t('dh_km_now'),
                  prefixIcon: const Icon(Icons.speed),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('dh_not_now'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('save'))),
          ],
        ),
      ),
    );

    if (saved == true) {
      final km = int.tryParse(kmCtrl.text.trim());
      if (km != null && km >= 0) {
        try {
          await _service.addOdometerReading(
            tenantId: widget.profile.tenantId,
            vehicleId: vehicleId,
            userId: widget.profile.id,
            readingKm: km,
          );
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(l.t('dh_km_saved'))));
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l.t('error')}: $e')));
          }
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final profile = widget.profile;
    final displayName = profile.appName;
    return Scaffold(
      // Atajo de voz: graba directamente sin entrar en "Añadir registro".
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('voice_shortcut_fab'),
        backgroundColor: Colors.amber.shade800,
        icon: const Icon(Icons.mic, color: Colors.white),
        label: Text(l.t('dh_voice_shortcut'), style: const TextStyle(color: Colors.white)),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AddRecordScreen(profile: profile, startOnVoice: true),
          ),
        ),
      ),
      appBar: widget.embedded
          ? null
          : AppBar(
              title: const Text('TaxiCount'),
              actions: [
                IconButton(
                  key: const Key('settings_button'),
                  tooltip: l.t('settings'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => SettingsScreen(profile: profile)),
                  ),
                  icon: const Icon(Icons.settings),
                ),
                IconButton(
                  tooltip: l.t('logout'),
                  onPressed: () => Supabase.instance.client.auth.signOut(),
                  icon: const Icon(Icons.logout),
                ),
              ],
            ),
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.local_taxi, size: 64, color: Colors.amber),
                const SizedBox(height: 12),
                Text(
                  l.t('dh_hello', {'name': displayName}),
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                _BigButton(
                  key: const Key('add_record_button'),
                  icon: Icons.add_circle,
                  label: l.t('dh_add_record'),
                  subtitle: l.t('dh_add_record_sub'),
                  color: Colors.amber.shade700,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => AddRecordScreen(profile: profile)),
                  ),
                ),
                const SizedBox(height: 16),
                _BigButton(
                  key: const Key('view_transactions_button'),
                  icon: Icons.receipt_long,
                  label: l.t('dh_view_tx'),
                  subtitle: l.t('dh_view_tx_sub'),
                  color: Colors.blueGrey,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => DriverTransactionsScreen(profile: profile),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Ambos disponibles: se puede iniciar y finalizar varias veces
                // el mismo día (p. ej. parar a comer y volver a empezar).
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        key: const Key('start_of_day_button'),
                        style: FilledButton.styleFrom(backgroundColor: Colors.green.shade700),
                        onPressed: _startDay,
                        icon: const Icon(Icons.wb_sunny),
                        label: Text(l.t('dh_start_day')),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        key: const Key('end_of_day_button'),
                        style: FilledButton.styleFrom(backgroundColor: Colors.blueGrey),
                        onPressed: _endOfDay,
                        icon: const Icon(Icons.nightlight_round),
                        label: Text(l.t('dh_finish_day')),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          ),
        ),
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;
  const _BigButton({
    super.key,
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
          child: Row(
            children: [
              Icon(icon, size: 40, color: Colors.white),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    const SizedBox(height: 4),
                    Text(subtitle, style: const TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white70),
            ],
          ),
        ),
      ),
    );
  }
}
