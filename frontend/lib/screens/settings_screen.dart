import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import 'incidents_screen.dart';
import 'locate_vehicle_screen.dart';
import 'subscription_screen.dart';

/// Ajustes. Cabecera con nombre/cuenta/vehículo (chofer) o empresa (jefe) y
/// acciones: idioma, reportar fallo, incidencias, suscripción/localizar, cuenta.
class SettingsScreen extends StatefulWidget {
  final Profile profile;
  const SettingsScreen({super.key, required this.profile});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _service = DataService();
  late String _displayName = widget.profile.appName;
  late String? _license = widget.profile.licenseNumber;
  String? _activeVehicleLabel;
  String? _companyName;
  bool _hasVehicles = false; // el conductor solo ve/elige coches asignados

  @override
  void initState() {
    super.initState();
    _loadHeader();
  }

  String _vehLabel(Map<String, dynamic> v) {
    final plate = (v['license_plate'] as String?) ?? '';
    final model = (v['model'] as String?) ?? '';
    if (plate.isNotEmpty && model.isNotEmpty) return '$plate · $model';
    return plate.isNotEmpty ? plate : (model.isNotEmpty ? model : 'Vehículo');
  }

  Future<void> _loadHeader() async {
    try {
      if (widget.profile.isOwner) {
        final b = await _service.fetchTenantBilling(widget.profile.tenantId);
        if (mounted) setState(() => _companyName = b?['name'] as String?);
      } else {
        final vid = await _service.todaysVehicleId(widget.profile.id);
        final vehicles = await _service.myVehicles();
        Map<String, dynamic>? v;
        for (final e in vehicles) {
          if (e['id'] == vid) { v = e; break; }
        }
        if (mounted) {
          setState(() {
            _hasVehicles = vehicles.isNotEmpty;
            _activeVehicleLabel = v == null ? null : _vehLabel(v);
          });
        }
      }
    } catch (_) {/* cabecera best-effort */}
  }

  Future<void> _editName() async {
    final l = context.l10n;
    final ctrl = TextEditingController(text: _displayName);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('set_edit_name')),
        content: TextField(
          key: const Key('display_name_field'),
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(helperText: l.t('set_name_hint'), border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('save'))),
        ],
      ),
    );
    if (ok == true) {
      try {
        await _service.updateDisplayName(ctrl.text);
        if (mounted) {
          setState(() => _displayName = ctrl.text.trim().isEmpty ? widget.profile.email : ctrl.text.trim());
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('set_name_updated'))));
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l.t('error')}: $e')));
      }
    }
  }

  Future<void> _editLicense() async {
    final l = context.l10n;
    final ctrl = TextEditingController(text: _license ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('set_license')),
        content: TextField(
          key: const Key('license_field'),
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('save'))),
        ],
      ),
    );
    if (ok == true) {
      try {
        await _service.updateLicenseNumber(ctrl.text);
        if (mounted) {
          setState(() => _license = ctrl.text.trim().isEmpty ? null : ctrl.text.trim());
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('set_name_updated'))));
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l.t('error')}: $e')));
      }
    }
  }

  Future<void> _changeVehicle() async {
    final l = context.l10n;
    final vehicles = await _service.myVehicles();
    if (!mounted) return;
    if (vehicles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('dh_no_vehicles'))));
      return;
    }
    // Preselecciona el vehículo activo de hoy si existe; si no, el primero.
    final activeId = await _service.todaysVehicleId(widget.profile.id);
    if (!mounted) return;
    var vehicleId = vehicles.any((v) => v['id'] == activeId)
        ? activeId!
        : vehicles.first['id'] as String;
    final kmCtrl = TextEditingController();
    Future<void> prefill(String vid) async => kmCtrl.text = (await _service.lastOdometer(vid))?.toString() ?? '';
    await prefill(vehicleId);
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(l.t('set_change_vehicle')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.t('set_change_vehicle_sub'),
                  style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: vehicleId,
                isExpanded: true,
                decoration: InputDecoration(labelText: l.t('dh_vehicle')),
                items: [for (final v in vehicles) DropdownMenuItem(value: v['id'] as String, child: Text(_vehLabel(v)))],
                onChanged: (val) async {
                  if (val == null) return;
                  vehicleId = val;
                  await prefill(val);
                  setLocal(() {});
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: kmCtrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: l.t('dh_km_now'), prefixIcon: const Icon(Icons.speed)),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('save'))),
          ],
        ),
      ),
    );
    if (ok == true) {
      final km = int.tryParse(kmCtrl.text.trim());
      try {
        await _service.addOdometerReading(
          tenantId: widget.profile.tenantId, vehicleId: vehicleId,
          userId: widget.profile.id, readingKm: km ?? 0);
        await _loadHeader();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('dh_km_saved'))));
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l.t('error')}: $e')));
      }
    }
  }

  Future<void> _pickLanguage() async {
    final current = localeController.value.languageCode;
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(ctx.l10n.t('set_language')),
        children: [
          for (final entry in kLanguageNames.entries)
            ListTile(
              leading: Text(_flag(entry.key), style: const TextStyle(fontSize: 24)),
              trailing: entry.key == current ? const Icon(Icons.check, color: Colors.green) : null,
              title: Text(entry.value),
              onTap: () => Navigator.pop(ctx, entry.key),
            ),
        ],
      ),
    );
    if (code != null) {
      await localeController.setLocale(code);
      if (mounted) setState(() {});
    }
  }

  String _flag(String code) => switch (code) { 'es' => '🇪🇸', 'en' => '🇬🇧', 'ca' => '🔵🟡', _ => '🏳️' };

  Future<void> _reportBug() async {
    final l = context.l10n;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('bug_title')),
        content: TextField(
          key: const Key('bug_body'),
          controller: ctrl,
          autofocus: true,
          maxLines: 4,
          decoration: InputDecoration(hintText: l.t('bug_hint'), border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('send'))),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      try {
        await _service.addIncident(tenantId: widget.profile.tenantId, kind: 'app', body: ctrl.text.trim());
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('bug_thanks'))));
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l.t('error')}: $e')));
      }
    }
  }

  void _open(Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  Future<void> _changeAccount() async {
    await Supabase.instance.client.auth.signOut();
    // Cierra Ajustes (y lo que haya encima) para que el AuthGate muestre el login.
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final isOwner = widget.profile.isOwner;
    return Scaffold(
      appBar: AppBar(title: Text(l.t('set_title'))),
      body: ListView(
        children: [
          _header(l, isOwner),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(l.t('set_language')),
            subtitle: Text('${_flag(localeController.value.languageCode)}  ${kLanguageNames[localeController.value.languageCode] ?? 'Español'}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickLanguage,
          ),
          ListTile(
            leading: const Icon(Icons.support_agent),
            title: Text(l.t('set_report_bug')),
            subtitle: Text(l.t('set_report_bug_sub')),
            onTap: _reportBug,
          ),
          if (!isOwner && _hasVehicles)
            ListTile(
              key: const Key('change_vehicle_tile'),
              leading: const Icon(Icons.directions_car),
              title: Text(l.t('set_change_vehicle')),
              subtitle: Text(_activeVehicleLabel == null
                  ? l.t('set_change_vehicle_sub')
                  : '${_activeVehicleLabel!}\n${l.t('set_change_vehicle_sub')}'),
              isThreeLine: _activeVehicleLabel != null,
              trailing: const Icon(Icons.chevron_right),
              onTap: _changeVehicle,
            ),
          ListTile(
            leading: const Icon(Icons.car_crash),
            title: Text(isOwner ? l.t('set_incidents_owner') : l.t('set_incidents_driver')),
            subtitle: Text(isOwner ? l.t('set_incidents_owner_sub') : l.t('set_incidents_driver_sub')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(IncidentsScreen(profile: widget.profile, standalone: true)),
          ),
          if (isOwner) ...[
            ListTile(
              leading: const Icon(Icons.workspace_premium_outlined),
              title: Text(l.t('nav_subscription')),
              subtitle: Text(l.t('set_subscription_sub')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(Scaffold(
                appBar: AppBar(title: Text(l.t('nav_subscription'))),
                body: SubscriptionScreen(profile: widget.profile),
              )),
            ),
            ListTile(
              leading: const Icon(Icons.my_location),
              title: Text(l.t('set_locate_vehicle')),
              subtitle: Text(l.t('set_locate_sub')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(LocateVehicleScreen(profile: widget.profile)),
            ),
          ],
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.switch_account),
            title: Text(l.t('set_change_account')),
            onTap: _changeAccount,
          ),
          AboutListTile(
            icon: const Icon(Icons.info_outline),
            applicationName: 'TaxiCount',
            applicationVersion: 'v1.0.0',
            child: Text(l.t('set_about')),
          ),
        ],
      ),
    );
  }

  Widget _header(AppLocalizations l, bool isOwner) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: Colors.amber,
            child: Icon(isOwner ? Icons.business : Icons.person, size: 30, color: Colors.white),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isOwner ? (_companyName ?? widget.profile.appName) : _displayName,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Text(widget.profile.email, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                if (isOwner)
                  Text(l.t('set_company'), style: const TextStyle(color: Colors.grey, fontSize: 12))
                else ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.directions_car, size: 14, color: Colors.grey),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          '${l.t('set_active_vehicle')}: ${_activeVehicleLabel ?? l.t('set_no_vehicle')}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  InkWell(
                    onTap: _editLicense,
                    child: Row(
                      children: [
                        Flexible(
                          child: Text('${l.t('set_license')}: ${_license ?? '—'}',
                              style: const TextStyle(color: Colors.grey, fontSize: 11)),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.edit, size: 12, color: Colors.grey),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (!isOwner)
            Column(
              children: [
                IconButton(
                  key: const Key('edit_name_button'),
                  tooltip: l.t('set_edit_name'),
                  icon: const Icon(Icons.edit),
                  onPressed: _editName,
                ),
                if (_hasVehicles)
                  IconButton(
                    key: const Key('change_vehicle_button'),
                    tooltip: l.t('set_change_vehicle'),
                    icon: const Icon(Icons.directions_car),
                    onPressed: _changeVehicle,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
