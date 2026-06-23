import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/profile.dart';
import '../services/data_service.dart';
import 'add_record_screen.dart';
import 'driver_transactions_screen.dart';

/// Home del Driver: elige entre añadir un registro o ver sus transacciones.
/// Al abrir, si procede, pide los km del coche con los que empieza el día.
class DriverHomeScreen extends StatefulWidget {
  final Profile profile;
  const DriverHomeScreen({super.key, required this.profile});

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> {
  final _service = DataService();
  bool _askedDailyKm = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAskDailyKm());
  }

  // Aviso in-app de km al empezar el día (una vez por sesión).
  Future<void> _maybeAskDailyKm() async {
    if (_askedDailyKm) return;
    _askedDailyKm = true;
    try {
      final vehicles = await _service.myVehicles();
      if (vehicles.isEmpty || !mounted) return;

      // Si ya hay lectura de hoy para alguno de sus vehículos, no molestamos.
      for (final v in vehicles) {
        if (await _service.hasOdometerToday(v['id'] as String, widget.profile.id)) {
          return;
        }
      }
      if (!mounted) return;
      await _showDailyKmDialog(vehicles);
    } catch (_) {/* no es crítico */}
  }

  Future<void> _showDailyKmDialog(List<Map<String, dynamic>> vehicles) async {
    var vehicleId = vehicles.first['id'] as String;
    final kmCtrl = TextEditingController();

    Future<void> prefill(String vid) async {
      final last = await _service.lastOdometer(vid);
      kmCtrl.text = last?.toString() ?? '';
    }

    await prefill(vehicleId);
    if (!mounted) return;

    String labelOf(Map<String, dynamic> v) {
      final plate = (v['license_plate'] as String?) ?? '';
      final model = (v['model'] as String?) ?? '';
      if (plate.isNotEmpty && model.isNotEmpty) return '$plate · $model';
      return plate.isNotEmpty ? plate : (model.isNotEmpty ? model : 'Vehículo');
    }

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Km al empezar el día'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (vehicles.length > 1) ...[
                DropdownButtonFormField<String>(
                  key: const Key('daily_km_vehicle'),
                  initialValue: vehicleId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Vehículo de hoy'),
                  items: [
                    for (final v in vehicles)
                      DropdownMenuItem(value: v['id'] as String, child: Text(labelOf(v))),
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
                decoration: const InputDecoration(
                  labelText: 'Km actuales del coche',
                  prefixIcon: Icon(Icons.speed),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Ahora no')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar')),
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
                .showSnackBar(const SnackBar(content: Text('Km guardados. ¡Buen día!')));
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
          }
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    final displayName = profile.name?.isNotEmpty == true ? profile.name! : profile.email;
    return Scaffold(
      appBar: AppBar(
        title: const Text('TaxiCount'),
        actions: [
          IconButton(
            tooltip: 'Cerrar sesión',
            onPressed: () => Supabase.instance.client.auth.signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Center(
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
                  '¡Hola, $displayName!',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                _BigButton(
                  key: const Key('add_record_button'),
                  icon: Icons.add_circle,
                  label: 'Añadir registro',
                  subtitle: 'Carrera o gasto (voz o manual)',
                  color: Colors.amber.shade700,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => AddRecordScreen(profile: profile)),
                  ),
                ),
                const SizedBox(height: 16),
                _BigButton(
                  key: const Key('view_transactions_button'),
                  icon: Icons.receipt_long,
                  label: 'Ver transacciones',
                  subtitle: 'Tu historial de carreras y gastos',
                  color: Colors.blueGrey,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => DriverTransactionsScreen(profile: profile),
                    ),
                  ),
                ),
              ],
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
