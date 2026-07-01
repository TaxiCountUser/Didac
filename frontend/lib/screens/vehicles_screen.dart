import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import 'vehicle_detail_screen.dart';

/// Panel de vehículos (solo Owner). Listar / añadir / dar de baja / nº licencia.
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
  bool _showInactive = false; // "mostrar inactivos" (historial de bajas)

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() => _future = _service.listVehicles(includeInactive: _showInactive));
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
    final license = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.t('vh_new')),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  key: const Key('plate_field'),
                  controller: plate,
                  decoration: InputDecoration(labelText: ctx.l10n.t('vh_plate')),
                  validator: (v) => (v == null || v.trim().isEmpty) ? ctx.l10n.t('vh_plate_required') : null,
                ),
                TextField(
                  key: const Key('model_field'),
                  controller: model,
                  decoration: InputDecoration(labelText: ctx.l10n.t('vh_model')),
                ),
                TextFormField(
                  key: const Key('initialkm_field'),
                  controller: km,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: ctx.l10n.t('vh_initial_km'),
                    suffixText: 'km',
                    helperText: ctx.l10n.t('vh_initial_km_hint'),
                    helperMaxLines: 2,
                  ),
                  validator: (v) {
                    final n = int.tryParse((v ?? '').trim());
                    if (n == null || n < 0) return ctx.l10n.t('vh_initial_km_required');
                    return null;
                  },
                ),
                TextField(
                  key: const Key('license_field'),
                  controller: license,
                  decoration: InputDecoration(
                    labelText: ctx.l10n.t('vh_license'),
                    helperText: ctx.l10n.t('vh_license_hint'),
                    helperMaxLines: 2,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.l10n.t('cancel'))),
          FilledButton(
            onPressed: () { if (formKey.currentState?.validate() ?? false) Navigator.pop(ctx, true); },
            child: Text(ctx.l10n.t('save')),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await _service.addVehicle(
          tenantId: widget.profile.tenantId,
          licensePlate: plate.text.trim(),
          initialOdometer: int.parse(km.text.trim()),
          model: model.text.trim().isEmpty ? null : model.text.trim(),
          licenseNumber: license.text.trim().isEmpty ? null : license.text.trim(),
        );
        _reload();
      } catch (e) {
        _showError(e);
      }
    }
  }

  /// Ver/editar el nº de licencia (solo el jefe; el conductor no lo ve).
  Future<void> _editLicense(Map<String, dynamic> vehicle) async {
    final id = vehicle['id'] as String;
    String current = '';
    try {
      current = (await _service.getVehicleLicense(id)) ?? '';
    } catch (_) {/* si falla, campo vacío */}
    if (!mounted) return;
    final ctrl = TextEditingController(text: current);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.t('vh_edit_license')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: ctx.l10n.t('vh_license')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.l10n.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.l10n.t('save'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _service.setVehicleLicense(id, ctrl.text.trim());
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.t('vh_license_saved'))));
    } catch (e) {
      _showError(e);
    }
  }

  /// Abre la ficha detallada del vehículo (km, mantenimiento, conductores).
  Future<void> _openDetail(Map<String, dynamic> vehicle) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => VehicleDetailScreen(profile: widget.profile, vehicle: vehicle),
    ));
    _reload();
  }

  /// Da de baja el vehículo (baja lógica, con confirmación). No se borra.
  Future<void> _deactivate(Map<String, dynamic> v) async {
    final plate = (v['license_plate'] as String?) ?? '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.t('vh_deactivate')),
        content: Text(ctx.l10n.t('vh_deactivate_confirm', {'plate': plate})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.l10n.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.l10n.t('vh_deactivate'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _service.deleteVehicle(v['id'] as String);
      _reload();
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _reactivate(String id) async {
    try {
      await _service.reactivateVehicle(id);
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
    final l = context.l10n;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add_vehicle_fab'),
        onPressed: _addDialog,
        icon: const Icon(Icons.add),
        label: Text(l.t('vh_add')),
      ),
      body: Column(
        children: [
          SwitchListTile(
            dense: true,
            title: Text(l.t('vh_show_inactive')),
            value: _showInactive,
            onChanged: (v) { _showInactive = v; _reload(); },
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
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
                  return Center(child: Text(l.t('vh_empty')));
                }
                return RefreshIndicator(
                  onRefresh: () async => _reload(),
                  child: ListView.separated(
                    itemCount: vehicles.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final v = vehicles[i];
                      final id = v['id'] as String;
                      final active = (v['active'] as bool?) ?? true;
                      final km = _km[id];
                      final parts = <String>[
                        (v['model'] as String?) ?? l.t('vh_no_model'),
                        if (km != null) '${NumberFormat.decimalPattern('es').format(km)} km',
                        if (!active) l.t('vh_inactive_badge'),
                      ];
                      return ListTile(
                        leading: Icon(Icons.directions_car, color: active ? null : Colors.grey),
                        title: Text((v['license_plate'] as String?) ?? '—'),
                        subtitle: Text(parts.join(' · ')),
                        onTap: () => _openDetail(v),
                        trailing: PopupMenuButton<String>(
                          onSelected: (sel) {
                            switch (sel) {
                              case 'license':
                                _editLicense(v);
                              case 'deactivate':
                                _deactivate(v);
                              case 'reactivate':
                                _reactivate(id);
                            }
                          },
                          itemBuilder: (ctx) => [
                            PopupMenuItem(
                              value: 'license',
                              child: ListTile(
                                leading: const Icon(Icons.badge_outlined),
                                title: Text(l.t('vh_edit_license')),
                              ),
                            ),
                            if (active)
                              PopupMenuItem(
                                value: 'deactivate',
                                child: ListTile(
                                  leading: const Icon(Icons.remove_circle_outline, color: Colors.orange),
                                  title: Text(l.t('vh_deactivate')),
                                ),
                              )
                            else
                              PopupMenuItem(
                                value: 'reactivate',
                                child: ListTile(
                                  leading: const Icon(Icons.add_circle_outline, color: Colors.green),
                                  title: Text(l.t('vh_reactivate')),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
