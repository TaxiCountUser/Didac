import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';

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

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => setState(() => _future = _service.listVehicles());

  Future<void> _addDialog() async {
    final plate = TextEditingController();
    final model = TextEditingController();
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
        );
        _reload();
      } catch (e) {
        _showError(e);
      }
    }
  }

  /// Asigna conductores a un vehículo (multi-selección).
  Future<void> _assignDrivers(Map<String, dynamic> vehicle) async {
    final vehicleId = vehicle['id'] as String;
    List<Map<String, dynamic>> drivers;
    Set<String> selected;
    try {
      drivers = await _service.listDrivers();
      final assigned = await _service.driversForVehicle(vehicleId);
      selected = assigned.map((d) => d['id'] as String).toSet();
    } catch (e) {
      _showError(e);
      return;
    }
    if (!mounted) return;
    if (drivers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.t('vh_no_drivers'))),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(ctx.l10n.t('vh_drivers_of', {'plate': '${vehicle['license_plate'] ?? ''}'})),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final d in drivers)
                  CheckboxListTile(
                    value: selected.contains(d['id']),
                    title: Text(d['name'] as String? ?? d['email'] as String),
                    subtitle: Text(d['email'] as String),
                    onChanged: (v) => setLocal(() {
                      if (v == true) {
                        selected.add(d['id'] as String);
                      } else {
                        selected.remove(d['id']);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.l10n.t('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.l10n.t('save'))),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        await _service.setDriversForVehicle(
          vehicleId: vehicleId,
          tenantId: widget.profile.tenantId,
          userIds: selected.toList(),
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.l10n.t('vh_assign_saved'))));
      } catch (e) {
        _showError(e);
      }
    }
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
                    trailing: const Icon(Icons.people_outline),
                    onTap: () => _assignDrivers(v),
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
