import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';

/// Detalle de una empresa para el administrador de plataforma: ve todos los
/// datos (suscripción, plan, días de uso, usuarios, recuentos), modifica la
/// suscripción/usuarios y puede eliminar usuarios o la empresa entera.
class AdminCompanyScreen extends StatefulWidget {
  final String tenantId;
  final String tenantName;
  const AdminCompanyScreen({super.key, required this.tenantId, required this.tenantName});

  @override
  State<AdminCompanyScreen> createState() => _AdminCompanyScreenState();
}

class _AdminCompanyScreenState extends State<AdminCompanyScreen> {
  final _service = DataService();
  late Future<Map<String, dynamic>> _future = _service.adminCompany(widget.tenantId);

  void _reload() => setState(() => _future = _service.adminCompany(widget.tenantId));

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
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {},
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.tenantName),
          actions: [
            IconButton(
              tooltip: l.t('refresh'),
              icon: const Icon(Icons.refresh),
              onPressed: _reload,
            ),
          ],
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
            return ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _subscriptionCard(l, tenant),
                const SizedBox(height: 8),
                _countsCard(l, counts),
                const SizedBox(height: 16),
                Text(l.t('admin_users_title'), style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                for (final u in users) _userTile(l, u),
                const SizedBox(height: 24),
                _dangerZone(l),
              ],
            );
          },
        ),
      ),
    );
  }

  // ---------- Tarjeta de suscripción / datos ----------
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
                  label: Text(status, style: const TextStyle(fontSize: 11)),
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

  // ---------- Usuarios ----------
  Widget _userTile(AppLocalizations l, Map<String, dynamic> u) {
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
        trailing: PopupMenuButton<String>(
          onSelected: (v) => _onUserAction(l, u, v),
          itemBuilder: (_) => [
            PopupMenuItem(value: 'toggle_active', child: Text(active ? l.t('admin_deactivate') : l.t('admin_activate'))),
            PopupMenuItem(value: 'toggle_admin', child: Text(isAdmin ? l.t('admin_remove_admin') : l.t('admin_make_admin_short'))),
            PopupMenuItem(value: 'role', child: Text(role == 'owner' ? l.t('admin_set_driver') : l.t('admin_set_owner'))),
            PopupMenuItem(value: 'delete', child: Text(l.t('admin_delete_user'), style: const TextStyle(color: Colors.red))),
          ],
        ),
      ),
    );
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

  // ---------- Editar suscripción ----------
  Future<void> _editSubscription(AppLocalizations l, Map<String, dynamic> t) async {
    String status = (t['subscription_status'] as String?) ?? 'trialing';
    String plan = (t['plan_id'] as String?) ?? '';
    final limitCtrl = TextEditingController(
        text: t['drivers_limit'] == null ? '' : '${t['drivers_limit']}');
    final extendCtrl = TextEditingController();

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
                  decoration: InputDecoration(labelText: l.t('admin_status')),
                  items: [for (final s in statuses) DropdownMenuItem(value: s, child: Text(s))],
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
                  decoration: InputDecoration(
                    labelText: l.t('admin_limit'),
                    hintText: l.t('sub_unlimited'),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: extendCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l.t('admin_extend_trial'),
                    hintText: l.t('admin_extend_hint'),
                  ),
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
    };
    final extend = int.tryParse(extendCtrl.text.trim());
    if (extend != null && extend > 0) patch['extend_trial_days'] = extend;

    await _guard(() => _service.adminUpdateCompany(widget.tenantId, patch), l.t('saved'));
  }

  // ---------- Zona peligrosa ----------
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
                  if (mounted) {
                    Navigator.pop(context, true); // vuelve a la lista y refresca
                  }
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
