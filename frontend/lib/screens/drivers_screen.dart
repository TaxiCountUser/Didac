import 'package:flutter/material.dart';

import '../models/profile.dart';
import '../services/data_service.dart';

/// Panel de conductores (solo Owner). Listar e invitar.
class DriversScreen extends StatefulWidget {
  final Profile profile;
  const DriversScreen({super.key, required this.profile});

  @override
  State<DriversScreen> createState() => _DriversScreenState();
}

class _DriversScreenState extends State<DriversScreen> {
  final _service = DataService();
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => setState(() => _future = _service.listDrivers());

  Future<void> _inviteDialog() async {
    final email = TextEditingController();
    final name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Invitar conductor'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('driver_email_field'),
              controller: email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            TextField(
              key: const Key('driver_name_field'),
              controller: name,
              decoration: const InputDecoration(labelText: 'Nombre'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Invitar')),
        ],
      ),
    );
    if (ok == true && email.text.trim().isNotEmpty) {
      try {
        final tempPwd = await _service.inviteDriver(
          email: email.text.trim(),
          name: name.text.trim().isEmpty ? null : name.text.trim(),
        );
        _reload();
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Conductor invitado'),
            content: Text(
              'Se ha creado el conductor.\n\n'
              'Contraseña temporal (desarrollo):\n$tempPwd',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
            ],
          ),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  /// Asigna vehículos a un conductor (multi-selección).
  Future<void> _assignVehicles(Map<String, dynamic> driver) async {
    final userId = driver['id'] as String;
    List<Map<String, dynamic>> vehicles;
    Set<String> selected;
    try {
      vehicles = await _service.listVehicles();
      final assigned = await _service.vehiclesForDriver(userId);
      selected = assigned.map((v) => v['id'] as String).toSet();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      return;
    }
    if (!mounted) return;
    if (vehicles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay vehículos. Añade alguno primero.')),
      );
      return;
    }
    final name = driver['name'] as String? ?? driver['email'] as String;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('Vehículos de $name'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final v in vehicles)
                  CheckboxListTile(
                    value: selected.contains(v['id']),
                    title: Text(v['license_plate'] as String? ?? '—'),
                    subtitle: Text(v['model'] as String? ?? 'Sin modelo'),
                    onChanged: (val) => setLocal(() {
                      if (val == true) {
                        selected.add(v['id'] as String);
                      } else {
                        selected.remove(v['id']);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar')),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        await _service.setVehiclesForDriver(
          userId: userId,
          tenantId: widget.profile.tenantId,
          vehicleIds: selected.toList(),
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Asignación guardada')));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('invite_driver_fab'),
        onPressed: _inviteDialog,
        icon: const Icon(Icons.person_add),
        label: const Text('Invitar'),
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
          final drivers = snap.data ?? [];
          if (drivers.isEmpty) {
            return const Center(child: Text('Aún no hay conductores. Invita al primero.'));
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView.separated(
              itemCount: drivers.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final d = drivers[i];
                return ListTile(
                  leading: const Icon(Icons.person),
                  title: Text(d['name'] as String? ?? d['email'] as String),
                  subtitle: Text(d['email'] as String),
                  trailing: const Icon(Icons.directions_car_outlined),
                  onTap: () => _assignVehicles(d),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
