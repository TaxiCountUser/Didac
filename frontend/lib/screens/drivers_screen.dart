import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
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
  String? _fleetCode;

  @override
  void initState() {
    super.initState();
    _reload();
    _loadCode();
  }

  void _reload() => setState(() => _future = _service.listDrivers());

  Future<void> _loadCode() async {
    try {
      final code = await _service.myFleetCode(widget.profile.tenantId);
      if (mounted) setState(() => _fleetCode = code);
    } catch (_) {/* no crítico */}
  }

  Widget _fleetCodeBanner() {
    final l = context.l10n;
    final code = _fleetCode;
    if (code == null || code.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: ListTile(
        leading: const Icon(Icons.key, color: Colors.amber),
        title: Text(l.t('dr_fleet_code')),
        subtitle: Text(l.t('dr_fleet_code_help')),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(code,
                style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 2, fontSize: 16)),
            IconButton(
              tooltip: l.t('copy'),
              icon: const Icon(Icons.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(l.t('copied'))));
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _inviteDialog() async {
    final email = TextEditingController();
    final name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.t('dr_invite_title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('driver_email_field'),
              controller: email,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(labelText: ctx.l10n.t('dr_email')),
            ),
            TextField(
              key: const Key('driver_name_field'),
              controller: name,
              decoration: InputDecoration(labelText: ctx.l10n.t('dr_name')),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.l10n.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.l10n.t('dr_invite'))),
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
            title: Text(ctx.l10n.t('dr_invited_title')),
            content: Text(ctx.l10n.t('dr_invited_msg', {'pwd': tempPwd})),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.l10n.t('ok'))),
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
        SnackBar(content: Text(context.l10n.t('dr_no_vehicles'))),
      );
      return;
    }
    final name = driver['name'] as String? ?? driver['email'] as String;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(ctx.l10n.t('dr_vehicles_of', {'name': name})),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final v in vehicles)
                  CheckboxListTile(
                    value: selected.contains(v['id']),
                    title: Text(v['license_plate'] as String? ?? '—'),
                    subtitle: Text(v['model'] as String? ?? ctx.l10n.t('vh_no_model')),
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
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.l10n.t('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.l10n.t('save'))),
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
            .showSnackBar(SnackBar(content: Text(context.l10n.t('vh_assign_saved'))));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  /// Edita el nombre que el jefe le pone al conductor.
  Future<void> _editName(Map<String, dynamic> driver) async {
    final ctrl = TextEditingController(text: driver['name'] as String? ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.t('dr_edit_name')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: ctx.l10n.t('dr_name')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.l10n.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.l10n.t('save'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _service.updateDriver(id: driver['id'] as String, name: ctrl.text.trim());
      _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  /// Define/actualiza el usuario y/o la contraseña que el jefe entrega al
  /// trabajador (para que entre con usuario o correo + contraseña).
  Future<void> _editCredentials(Map<String, dynamic> driver) async {
    final user = TextEditingController(text: driver['username'] as String? ?? '');
    final pass = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.t('dr_credentials_title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(ctx.l10n.t('dr_credentials_help'), style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: user,
              decoration: InputDecoration(labelText: ctx.l10n.t('dr_username')),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: pass,
              decoration: InputDecoration(
                labelText: ctx.l10n.t('dr_new_password'),
                helperText: ctx.l10n.t('dr_password_hint'),
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
    if (ok != true) return;
    try {
      await _service.updateDriver(
        id: driver['id'] as String,
        username: user.text.trim(),
        password: pass.text.trim().isEmpty ? null : pass.text.trim(),
      );
      _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.t('dr_credentials_saved'))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  /// Saca al conductor de la flota (active=false) o lo reincorpora (true).
  Future<void> _toggleActive(Map<String, dynamic> driver) async {
    final isActive = (driver['active'] as bool?) ?? true;
    final name = driver['name'] as String? ?? driver['email'] as String;
    if (isActive) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(ctx.l10n.t('dr_remove_title')),
          content: Text(ctx.l10n.t('dr_remove_msg', {'name': name})),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.l10n.t('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.l10n.t('dr_remove'))),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await _service.updateDriver(id: driver['id'] as String, active: !isActive);
      _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  /// Elimina definitivamente la cuenta del conductor.
  Future<void> _confirmDelete(Map<String, dynamic> driver) async {
    final name = driver['name'] as String? ?? driver['email'] as String;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.t('dr_delete_title')),
        content: Text(ctx.l10n.t('dr_delete_msg', {'name': name})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.l10n.t('cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.l10n.t('delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _service.deleteDriver(driver['id'] as String);
      _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('invite_driver_fab'),
        onPressed: _inviteDialog,
        icon: const Icon(Icons.person_add),
        label: Text(context.l10n.t('dr_invite')),
      ),
      body: Column(
        children: [
          _fleetCodeBanner(),
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
          final drivers = snap.data ?? [];
          if (drivers.isEmpty) {
            return Center(child: Text(context.l10n.t('dr_empty')));
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView.separated(
              itemCount: drivers.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final d = drivers[i];
                final isActive = (d['active'] as bool?) ?? true;
                final username = d['username'] as String?;
                final l = context.l10n;
                final subtitle = [
                  d['email'] as String,
                  if (username != null && username.isNotEmpty) '@$username',
                  if (!isActive) l.t('dr_out_of_fleet'),
                ].join(' · ');
                return ListTile(
                  leading: Icon(isActive ? Icons.person : Icons.person_off,
                      color: isActive ? null : Colors.grey),
                  title: Text(d['name'] as String? ?? d['email'] as String),
                  subtitle: Text(subtitle),
                  onTap: isActive ? () => _assignVehicles(d) : null,
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) {
                      switch (v) {
                        case 'vehicles':
                          _assignVehicles(d);
                        case 'name':
                          _editName(d);
                        case 'credentials':
                          _editCredentials(d);
                        case 'active':
                          _toggleActive(d);
                        case 'delete':
                          _confirmDelete(d);
                      }
                    },
                    itemBuilder: (ctx) => [
                      if (isActive)
                        PopupMenuItem(
                          value: 'vehicles',
                          child: ListTile(
                            leading: const Icon(Icons.directions_car_outlined),
                            title: Text(l.t('dr_assign_vehicles')),
                          ),
                        ),
                      PopupMenuItem(
                        value: 'name',
                        child: ListTile(
                          leading: const Icon(Icons.badge_outlined),
                          title: Text(l.t('dr_edit_name')),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'credentials',
                        child: ListTile(
                          leading: const Icon(Icons.password),
                          title: Text(l.t('dr_credentials_title')),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'active',
                        child: ListTile(
                          leading: Icon(isActive ? Icons.person_off : Icons.person_add_alt),
                          title: Text(isActive ? l.t('dr_remove') : l.t('dr_reactivate')),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: ListTile(
                          leading: const Icon(Icons.delete_outline, color: Colors.red),
                          title: Text(l.t('delete'), style: const TextStyle(color: Colors.red)),
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
