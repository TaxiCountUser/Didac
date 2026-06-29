import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import 'vehicle_detail_screen.dart';

/// Panel de vehículos (solo Owner). Listar / añadir / eliminar.
class VehiclesScreen extends StatefulWidget {
  final Profile profile;
  const VehiclesScreen({super.key, required this.profile});

  @override
  State<VehiclesScreen> createState() => _VehiclesScreenState();
}

class _VehiclesScreenState extends State<VehiclesScreen> {
  final _service = DataService();
  late Future<List<Map<String, dynamic>>> _future;
  Map<String, int> _km = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() => _future = _service.listVehicles());
    _loadKm();
  }

  Future<void> _loadKm() async {
    try {
      final vehicles = await _future;
      final km = await _service.currentKmFor([for (final v in vehicles) v['id'] as String]);
      if (mounted) setState(() => _km = km);
    } catch (_) {/* km best-effort */}
  }

  Future<void> _addDialog() async {
    final plate = TextEditingController();
    final model = TextEditingController();
    final km = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.t('vh_new')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('plate_field'),
              controller: plate,
              decoration: InputDecoration(labelText: ctx.l10n.t('vh_plate')),
            ),
            TextField(
              key: const Key('model_field'),
              controller: model,
              decoration: InputDecoration(labelText: ctx.l10n.t('vh_model')),
            ),
            TextField(
              key: const Key('regkm_field'),
              controller: km,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: ctx.l10n.t('vh_registered_km'),
                suffixText: 'km',
                helperText: ctx.l10n.t('vh_registered_km_hint'),
                helperMaxLines: 2,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.l10n.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.l10n.t('save'))),
        ],
      ),
    );
    if (ok == true && plate.text.trim().isNotEmpty) {
      try {
        await _service.addVehicle(
          tenantId: widget.profile.tenantId,
          licensePlate: plate.text.trim(),
          model: model.text.trim().isEmpty ? null : model.text.trim(),
          registeredKm: int.tryParse(km.text.trim()),
        );
        _reload();
      } catch (e) {
        _showError(e);
      }
    }
  }

  /// Abre la ficha detallada del vehículo (km, mantenimiento, conductores).
  Future<void> _openDetail(Map<String, dynamic> vehicle) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => VehicleDetailScreen(profile: widget.profile, vehicle: vehicle),
    ));
    _reload();
  }

  /// Pequeña insignia con los km actuales del coche (si se conocen).
  Widget _kmBadge(BuildContext context, String vehicleId) {
    final km = _km[vehicleId];
    if (km == null) return const Icon(Icons.chevron_right);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('${NumberFormat.decimalPattern('es').format(km)} km',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(width: 4),
        const Icon(Icons.chevron_right),
      ],
    );
  }

  Future<void> _delete(String id) async {
    try {
      await _service.deleteVehicle(id);
      _reload();
    } catch (e) {
      _showError(e);
    }
  }

  void _showError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Error: $e')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add_vehicle_fab'),
        onPressed: _addDialog,
        icon: const Icon(Icons.add),
        label: Text(context.l10n.t('vh_add')),
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
          final vehicles = snap.data ?? [];
          if (vehicles.isEmpty) {
            return Center(child: Text(context.l10n.t('vh_empty')));
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView.separated(
              itemCount: vehicles.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final v = vehicles[i];
                return Dismissible(
                  key: ValueKey(v['id']),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: Colors.red,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  onDismissed: (_) => _delete(v['id'] as String),
                  child: ListTile(
                    leading: const Icon(Icons.directions_car),
                    title: Text(v['license_plate'] as String? ?? '—'),
                    subtitle: Text(v['model'] as String? ?? context.l10n.t('vh_no_model')),
                    trailing: _kmBadge(context, v['id'] as String),
                    onTap: () => _openDetail(v),
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
