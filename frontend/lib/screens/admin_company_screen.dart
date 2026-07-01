import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import 'admin_incident_chat_screen.dart';

/// Etiqueta legible del estado de suscripción (trialing -> "Periodo de prueba"...).
String adminStatusLabel(AppLocalizations l, String? s) => l.t(switch (s) {
      'active' => 'st_active',
      'trialing' => 'st_trial',
      'past_due' => 'st_past_due',
      'canceled' => 'st_canceled',
      _ => 'st_inactive',
    });

/// Gestión completa de una empresa para el administrador de plataforma, como si
/// fuera la suya: pestañas Resumen, Vehículos, Conductores e Incidencias, con
/// posibilidad de ver y modificar (reparar) sus datos.
class AdminCompanyScreen extends StatefulWidget {
  final String tenantId;
  final String tenantName;
  const AdminCompanyScreen({super.key, required this.tenantId, required this.tenantName});

  @override
  State<AdminCompanyScreen> createState() => _AdminCompanyScreenState();
}

class _AdminCompanyScreenState extends State<AdminCompanyScreen>
    with SingleTickerProviderStateMixin {
  final _service = DataService();
  late final TabController _tabs = TabController(length: 4, vsync: this);
  late Future<Map<String, dynamic>> _future = _service.adminCompany(widget.tenantId);

  void _reload() => setState(() => _future = _service.adminCompany(widget.tenantId));

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _toast(String msg) async {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _guard(Future<void> Function() action, String okMsg) async {
    try {
      await action();
      await _toast(okMsg);
      _reload();
    } catch (e) {
      await _toast('Error: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.tenantName),
        actions: [
          IconButton(tooltip: l.t('refresh'), icon: const Icon(Icons.refresh), onPressed: _reload),
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: [
            Tab(text: l.t('admin_tab_summary')),
            Tab(text: l.t('admin_tab_vehicles')),
            Tab(text: l.t('admin_tab_drivers')),
            Tab(text: l.t('admin_tab_incidents')),
          ],
        ),
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${l.t('error')}: ${snap.error.toString().replaceFirst('Exception: ', '')}'),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _reload, child: Text(l.t('retry'))),
                ],
              ),
            );
          }
          final data = snap.data ?? {};
          final tenant = (data['tenant'] as Map?)?.cast<String, dynamic>() ?? {};
          final users = ((data['users'] as List?) ?? []).cast<Map<String, dynamic>>();
          final counts = (data['counts'] as Map?)?.cast<String, dynamic>() ?? {};
          final vehicles = ((data['vehicles_list'] as List?) ?? []).cast<Map<String, dynamic>>();
          final incidents = ((data['incidents_list'] as List?) ?? []).cast<Map<String, dynamic>>();
          return TabBarView(
            controller: _tabs,
            children: [
              _summaryTab(l, tenant, counts),
              _vehiclesTab(l, vehicles),
              _driversTab(l, users, vehicles),
              _incidentsTab(l, incidents),
            ],
          );
        },
      ),
    );
  }

  // ===================== TAB 1: RESUMEN =====================
  Widget _summaryTab(AppLocalizations l, Map<String, dynamic> tenant,
      Map<String, dynamic> counts) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _subscriptionCard(l, tenant),
        const SizedBox(height: 8),
        _maskedFinanceCard(l),
        const SizedBox(height: 8),
        _countsCard(l, counts),
        const SizedBox(height: 16),
        _dangerZone(l),
      ],
    );
  }

  // Protección de datos: el admin de plataforma NO ve el dinero de la empresa
  // ni el contenido de las carreras. Se muestra un aviso en vez de las cifras.
  Widget _maskedFinanceCard(AppLocalizations l) {
    return Card(
      color: Colors.blueGrey.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.lock_outline, color: Colors.blueGrey),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('*****',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 2)),
                  const SizedBox(height: 4),
                  Text(l.t('admin_financials_masked'),
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _subscriptionCard(AppLocalizations l, Map<String, dynamic> t) {
    final created = DateTime.tryParse('${t['created_at']}')?.toLocal();
    final trialEnds = DateTime.tryParse('${t['trial_ends_at']}')?.toLocal();
    final daysUsing = created == null ? null : DateTime.now().difference(created).inDays;
    final trialLeft = (trialEnds != null && DateTime.now().isBefore(trialEnds))
        ? trialEnds.difference(DateTime.now()).inDays + 1
        : 0;
    final status = (t['subscription_status'] as String?) ?? 'inactive';
    final plan = (t['plan_id'] as String?) ?? '—';
    final limit = t['drivers_limit'] == null ? l.t('sub_unlimited') : '${t['drivers_limit']}';
    final solo = t['solo'] == true;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(solo ? Icons.person_pin_circle : Icons.business,
                    color: solo ? Colors.teal : Colors.amber.shade800),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(solo ? l.t('admin_mode_solo') : l.t('admin_mode_fleet'),
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                Chip(
                  label: Text(adminStatusLabel(l, status), style: const TextStyle(fontSize: 11)),
                  backgroundColor: status == 'active'
                      ? Colors.green.shade100
                      : (status == 'trialing' ? Colors.blue.shade100 : Colors.red.shade100),
                ),
              ],
            ),
            const Divider(),
            _row(l.t('admin_plan'), plan),
            _row(l.t('sub_drivers_included', {'n': limit}), ''),
            _row(l.t('admin_days_using'), daysUsing == null ? '—' : '$daysUsing'),
            _row(l.t('admin_trial_left'), trialLeft > 0 ? '$trialLeft' : l.t('admin_trial_over')),
            if ((t['join_code'] as String?)?.isNotEmpty == true)
              _row(l.t('admin_join_code'), '${t['join_code']}'),
            if ((t['stripe_customer_id'] as String?)?.isNotEmpty == true)
              _row('Stripe', l.t('admin_has_stripe')),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.edit),
                label: Text(l.t('admin_edit_sub')),
                onPressed: () => _editSubscription(l, t),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _countsCard(AppLocalizations l, Map<String, dynamic> c) {
    return Card(
      color: Colors.grey.shade100,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _stat('${c['vehicles'] ?? 0}', l.t('nav_vehicles')),
            _stat('${c['transactions'] ?? 0}', l.t('admin_transactions')),
            _stat('${c['incidents'] ?? 0}', l.t('admin_incidents')),
          ],
        ),
      ),
    );
  }

  Widget _stat(String v, String label) => Column(
        children: [
          Text(v, style: Theme.of(context).textTheme.headlineSmall),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      );

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 5, child: Text(k, style: const TextStyle(color: Colors.black54))),
            if (v.isNotEmpty)
              Expanded(flex: 4, child: Text(v, textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
          ],
        ),
      );

  // ===================== TAB 2: VEHÍCULOS =====================
  Widget _vehiclesTab(AppLocalizations l, List<Map<String, dynamic>> vehicles) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _vehicleDialog(l),
        icon: const Icon(Icons.add),
        label: Text(l.t('admin_add_vehicle')),
      ),
      body: vehicles.isEmpty
          ? Center(child: Text(l.t('admin_no_vehicles')))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [for (final v in vehicles) _vehicleTile(l, v)],
            ),
    );
  }

  Widget _vehicleTile(AppLocalizations l, Map<String, dynamic> v) {
    final plate = (v['license_plate'] as String?) ?? '';
    final model = (v['model'] as String?) ?? '';
    return Card(
      child: ListTile(
        leading: const Icon(Icons.directions_car),
        title: Text(plate),
        subtitle: model.isEmpty ? null : Text(model),
        trailing: PopupMenuButton<String>(
          onSelected: (a) {
            if (a == 'edit') {
              _vehicleDialog(l, vehicle: v);
            } else if (a == 'delete') {
              _confirm(l, l.t('admin_delete_vehicle'), '${l.t('admin_delete_vehicle')}: $plate?').then((ok) {
                if (ok) _guard(() => _service.adminDeleteVehicle(v['id'] as String), l.t('admin_deleted'));
              });
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'edit', child: Text(l.t('edit'))),
            PopupMenuItem(value: 'delete', child: Text(l.t('admin_delete_vehicle'), style: const TextStyle(color: Colors.red))),
          ],
        ),
      ),
    );
  }

  Future<void> _vehicleDialog(AppLocalizations l, {Map<String, dynamic>? vehicle}) async {
    final plateCtrl = TextEditingController(text: (vehicle?['license_plate'] as String?) ?? '');
    final modelCtrl = TextEditingController(text: (vehicle?['model'] as String?) ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(vehicle == null ? l.t('admin_add_vehicle') : l.t('edit')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: plateCtrl, decoration: InputDecoration(labelText: l.t('admin_vehicle_plate'))),
            const SizedBox(height: 8),
            TextField(controller: modelCtrl, decoration: InputDecoration(labelText: l.t('admin_vehicle_model'))),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('save'))),
        ],
      ),
    );
    if (ok != true || plateCtrl.text.trim().isEmpty) return;
    if (vehicle == null) {
      await _guard(() => _service.adminAddVehicle(widget.tenantId, plateCtrl.text.trim(), modelCtrl.text.trim()), l.t('saved'));
    } else {
      await _guard(() => _service.adminUpdateVehicle(vehicle['id'] as String, plate: plateCtrl.text.trim(), model: modelCtrl.text.trim()), l.t('saved'));
    }
  }

  // ===================== TAB 3: CONDUCTORES =====================
  Widget _driversTab(AppLocalizations l, List<Map<String, dynamic>> users, List<Map<String, dynamic>> vehicles) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [for (final u in users) _userTile(l, u, vehicles)],
    );
  }

  Widget _userTile(AppLocalizations l, Map<String, dynamic> u, List<Map<String, dynamic>> vehicles) {
    final email = (u['email'] as String?) ?? '—';
    final role = (u['role'] as String?) ?? 'driver';
    final active = u['active'] != false;
    final isAdmin = u['is_admin'] == true;
    return Card(
      child: ListTile(
        leading: Icon(role == 'owner' ? Icons.badge : Icons.person,
            color: active ? Colors.green : Colors.grey),
        title: Text(email, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text([
          role == 'owner' ? l.t('admin_role_owner') : l.t('admin_role_driver'),
          if (!active) l.t('admin_inactive'),
          if (isAdmin) 'ADMIN',
        ].join(' · ')),
        // Tocar el conductor: asignar qué vehículos usa.
        onTap: () => _assignVehiclesDialog(l, u, vehicles),
        trailing: PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'vehicles') {
              _assignVehiclesDialog(l, u, vehicles);
            } else {
              _onUserAction(l, u, v);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'vehicles', child: Text(l.t('dr_assign_vehicles'))),
            PopupMenuItem(value: 'toggle_active', child: Text(active ? l.t('admin_deactivate') : l.t('admin_activate'))),
            PopupMenuItem(value: 'toggle_admin', child: Text(isAdmin ? l.t('admin_remove_admin') : l.t('admin_make_admin_short'))),
            PopupMenuItem(value: 'role', child: Text(role == 'owner' ? l.t('admin_set_driver') : l.t('admin_set_owner'))),
            PopupMenuItem(value: 'delete', child: Text(l.t('admin_delete_user'), style: const TextStyle(color: Colors.red))),
          ],
        ),
      ),
    );
  }

  // Asignar qué vehículos usa un conductor (admin), como si fuera la empresa.
  Future<void> _assignVehiclesDialog(AppLocalizations l, Map<String, dynamic> u, List<Map<String, dynamic>> vehicles) async {
    final userId = u['id'] as String;
    if (vehicles.isEmpty) {
      await _toast(l.t('admin_no_vehicles'));
      return;
    }
    Set<String> selected;
    try {
      selected = (await _service.adminUserVehicles(userId)).toSet();
    } catch (e) {
      await _toast('Error: ${e.toString().replaceFirst('Exception: ', '')}');
      return;
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(l.t('dr_vehicles_of', {'name': (u['email'] as String?) ?? ''})),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final v in vehicles)
                  CheckboxListTile(
                    value: selected.contains(v['id']),
                    title: Text((v['license_plate'] as String?) ?? '—'),
                    subtitle: Text((v['model'] as String?) ?? ''),
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
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('save'))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _guard(() => _service.adminSetUserVehicles(userId, selected.toList()), l.t('saved'));
  }

  Future<void> _onUserAction(AppLocalizations l, Map<String, dynamic> u, String action) async {
    final id = u['id'] as String;
    switch (action) {
      case 'toggle_active':
        await _guard(() => _service.adminUpdateUser(id, {'active': !(u['active'] != false)}), l.t('saved'));
        break;
      case 'toggle_admin':
        await _guard(() => _service.adminUpdateUser(id, {'is_admin': !(u['is_admin'] == true)}), l.t('saved'));
        break;
      case 'role':
        final newRole = (u['role'] == 'owner') ? 'driver' : 'owner';
        await _guard(() => _service.adminUpdateUser(id, {'role': newRole}), l.t('saved'));
        break;
      case 'delete':
        final ok = await _confirm(l, l.t('admin_delete_user'), l.t('admin_delete_user_confirm', {'email': '${u['email']}'}));
        if (ok) await _guard(() => _service.adminDeleteUser(id), l.t('admin_deleted'));
        break;
    }
  }

  // ===================== TAB 4: INCIDENCIAS =====================
  Widget _incidentsTab(AppLocalizations l, List<Map<String, dynamic>> incidents) {
    if (incidents.isEmpty) return Center(child: Text(l.t('admin_no_incidents')));
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [for (final i in incidents) _incidentTile(l, i)],
    );
  }

  Widget _incidentTile(AppLocalizations l, Map<String, dynamic> inc) {
    final body = (inc['body'] as String?) ?? '';
    final kind = (inc['kind'] as String?) ?? 'nota';
    final status = (inc['status'] as String?) ?? 'abierta';
    final author = ((inc['users'] as Map?)?['email'] as String?) ?? '';
    final resolved = status == 'resuelta';
    return Card(
      child: ListTile(
        leading: Icon(kind == 'app' ? Icons.bug_report : Icons.note_alt,
            color: kind == 'app' ? Colors.deepPurple : Colors.blueGrey),
        title: Text(body, maxLines: 3, overflow: TextOverflow.ellipsis),
        subtitle: Text(author),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: resolved ? l.t('admin_reopen') : l.t('admin_resolve'),
              icon: Icon(resolved ? Icons.replay : Icons.check_circle,
                  color: resolved ? Colors.orange : Colors.green),
              onPressed: () => _guard(
                () => _service.adminSetIncidentStatus(inc['id'] as String, resolved ? 'abierta' : 'resuelta'),
                l.t('saved'),
              ),
            ),
            const Icon(Icons.chat_bubble_outline, size: 18),
          ],
        ),
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => AdminIncidentChatScreen(incident: inc),
          ));
          _reload();
        },
      ),
    );
  }

  // ===================== Editar suscripción =====================
  Future<void> _editSubscription(AppLocalizations l, Map<String, dynamic> t) async {
    String status = (t['subscription_status'] as String?) ?? 'trialing';
    String plan = (t['plan_id'] as String?) ?? '';
    final limitCtrl = TextEditingController(
        text: t['drivers_limit'] == null ? '' : '${t['drivers_limit']}');
    final extendCtrl = TextEditingController();
    final codeCtrl = TextEditingController(text: (t['join_code'] as String?) ?? '');

    const statuses = ['active', 'trialing', 'past_due', 'canceled', 'inactive'];
    const plans = ['', 'starter', 'pro', 'business'];

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(l.t('admin_edit_sub')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: status,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: l.t('admin_status')),
                  items: [
                    for (final s in statuses)
                      DropdownMenuItem(value: s, child: Text('${adminStatusLabel(l, s)} ($s)')),
                  ],
                  onChanged: (v) => setLocal(() => status = v ?? status),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: plan,
                  decoration: InputDecoration(labelText: l.t('admin_plan')),
                  items: [
                    for (final p in plans)
                      DropdownMenuItem(value: p, child: Text(p.isEmpty ? '—' : p)),
                  ],
                  onChanged: (v) => setLocal(() => plan = v ?? plan),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: limitCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: l.t('admin_limit'), hintText: l.t('sub_unlimited')),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: extendCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: l.t('admin_extend_trial'), hintText: l.t('admin_extend_hint')),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: codeCtrl,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(labelText: l.t('admin_join_code')),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('save'))),
          ],
        ),
      ),
    );
    if (saved != true) return;
    final patch = <String, dynamic>{
      'subscription_status': status,
      'plan_id': plan,
      'drivers_limit': limitCtrl.text.trim().isEmpty ? null : limitCtrl.text.trim(),
      'join_code': codeCtrl.text.trim(),
    };
    final extend = int.tryParse(extendCtrl.text.trim());
    if (extend != null && extend > 0) patch['extend_trial_days'] = extend;
    await _guard(() => _service.adminUpdateCompany(widget.tenantId, patch), l.t('saved'));
  }

  // ===================== Zona peligrosa =====================
  Widget _dangerZone(AppLocalizations l) {
    return Card(
      color: Colors.red.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.t('admin_danger'), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(l.t('admin_delete_company_help'), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
              icon: const Icon(Icons.delete_forever),
              label: Text(l.t('admin_delete_company')),
              onPressed: () async {
                final ok = await _confirm(l, l.t('admin_delete_company'),
                    l.t('admin_delete_company_confirm', {'name': widget.tenantName}));
                if (!ok) return;
                try {
                  await _service.adminDeleteCompany(widget.tenantId);
                  if (mounted) Navigator.pop(context, true);
                } catch (e) {
                  await _toast('Error: ${e.toString().replaceFirst('Exception: ', '')}');
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirm(AppLocalizations l, String title, String msg) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(msg),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.t('admin_delete_confirm_btn')),
          ),
        ],
      ),
    );
    return ok == true;
  }
}
