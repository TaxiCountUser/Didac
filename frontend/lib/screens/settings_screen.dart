import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import '../widgets/lang_flag.dart';
import 'admin_screen.dart';
import 'incidents_screen.dart';
import 'challenges_screen.dart';
import 'referral_screen.dart';
import 'tickets_screen.dart';
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
  late String? _avatarB64 = widget.profile.avatarUrl; // foto base64 o null = icono
  late String? _username = widget.profile.username; // para login con usuario
  String? _activeVehicleLabel;
  String? _companyName;
  int _vehicleCount = 0; // nº de coches del conductor; el cambio solo si hay >1
  bool _subActive = false; // suscripción activa de pago o prueba vigente (referidos)
  bool _newReply = false; // el admin ha contestado a un ticket (aviso)

  @override
  void initState() {
    super.initState();
    _loadHeader();
    _loadTicketBadge();
  }

  // ¿El admin ha respondido a algún ticket desde la última vez que los vi?
  Future<void> _loadTicketBadge() async {
    try {
      final latest = await _service.latestTicketReplyAt();
      if (latest == null) return;
      final prefs = await SharedPreferences.getInstance();
      final seenStr = prefs.getString('tickets_seen_at');
      final seen = seenStr == null ? null : DateTime.tryParse(seenStr);
      if (mounted && (seen == null || latest.isAfter(seen))) {
        setState(() => _newReply = true);
      }
    } catch (_) {/* aviso best-effort */}
  }

  Future<void> _openTickets() async {
    // Marcar como visto: al abrir, se considera leído.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('tickets_seen_at', DateTime.now().toIso8601String());
    if (mounted) setState(() => _newReply = false);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TicketsScreen(profile: widget.profile)),
    );
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
        if (mounted) {
          setState(() {
            _companyName = b?['name'] as String?;
            // "Invita y Gana" para empresarios con suscripción activa de pago
            // o en periodo de prueba todavía vigente.
            final st = b?['subscription_status'] as String?;
            DateTime? trialEnds;
            final rawTrial = b?['trial_ends_at'];
            if (rawTrial is String && rawTrial.isNotEmpty) {
              trialEnds = DateTime.tryParse(rawTrial);
            }
            final trialVigente =
                trialEnds != null && DateTime.now().isBefore(trialEnds);
            _subActive = st == 'active' ||
                st == 'past_due' ||
                (st == 'trialing' && trialVigente) ||
                trialVigente;
          });
        }
      } else {
        final vid = await _service.todaysVehicleId(widget.profile.id);
        final vehicles = await _service.myVehicles();
        Map<String, dynamic>? v;
        for (final e in vehicles) {
          if (e['id'] == vid) { v = e; break; }
        }
        if (mounted) {
          setState(() {
            _vehicleCount = vehicles.length;
            _activeVehicleLabel = v == null ? null : _vehLabel(v);
          });
        }
      }
    } catch (_) {/* cabecera best-effort */}
  }

  Future<void> _editUsername() async {
    final l = context.l10n;
    final ctrl = TextEditingController(text: _username ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('set_username')),
        content: TextField(
          key: const Key('username_field'),
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            helperText: l.t('set_username_hint'), helperMaxLines: 2,
            border: const OutlineInputBorder(), prefixText: '@',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('save'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _service.updateUsername(ctrl.text);
      if (mounted) {
        setState(() => _username = ctrl.text.trim().isEmpty ? null : ctrl.text.trim());
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('set_name_updated'))));
      }
    } catch (e) {
      final taken = e.toString().contains('23505') || e.toString().toLowerCase().contains('duplicate');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(taken ? l.t('set_username_taken') : '${l.t('error')}: $e')));
      }
    }
  }

  // Avatar: elegir foto (comprimida a base64) o quitarla (vuelve al icono).
  // El cambio es solo en la cuenta del propio usuario.
  Future<void> _editAvatar() async {
    final l = context.l10n;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text(l.t('set_pick_photo')),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: Text(l.t('set_take_photo')),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            if (_avatarB64 != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(l.t('set_remove_photo')),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (action == null) return;
    try {
      if (action == 'remove') {
        await _service.updateAvatar(null);
        if (mounted) setState(() => _avatarB64 = null);
        return;
      }
      final picker = ImagePicker();
      final x = await picker.pickImage(
        source: action == 'camera' ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 256, maxHeight: 256, imageQuality: 60,
      );
      if (x == null) return;
      final bytes = await x.readAsBytes();
      final b64 = base64Encode(bytes);
      await _service.updateAvatar(b64);
      if (mounted) {
        setState(() => _avatarB64 = b64);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('set_name_updated'))));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l.t('error')}: $e')));
    }
  }

  Future<void> _editCompanyName() async {
    final l = context.l10n;
    final ctrl = TextEditingController(text: _companyName ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('set_edit_company')),
        content: TextField(
          key: const Key('company_name_field'),
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('save'))),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      try {
        await _service.updateCompanyName(widget.profile.tenantId, ctrl.text.trim());
        if (mounted) {
          setState(() => _companyName = ctrl.text.trim());
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('set_name_updated'))));
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l.t('error')}: $e')));
      }
    }
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
              leading: LangFlag(entry.key, size: 24),
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

  void _open(Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  /// Formulario para informar de un error de la app (va al equipo de TaxiCount
  /// con copia al jefe). Unidireccional: no espera respuesta en un chat.
  Future<void> _reportErrorDialog() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.t('err_report_title')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 5,
          maxLength: 4000,
          decoration: InputDecoration(
            hintText: ctx.l10n.t('err_report_hint'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.l10n.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.l10n.t('err_report_send'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final text = ctrl.text.trim();
    if (text.length < 3) return;
    final device = 'app · ${widget.profile.isOwner ? 'owner' : 'driver'} · ${Theme.of(context).platform.name}';
    try {
      await _service.submitErrorReport(description: text, deviceInfo: device);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.t('err_report_sent'))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

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
            subtitle: Row(
              children: [
                LangFlag(localeController.value.languageCode, size: 18),
                const SizedBox(width: 8),
                Text(kLanguageNames[localeController.value.languageCode] ?? 'Español'),
              ],
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickLanguage,
          ),
          ListTile(
            leading: const Icon(Icons.alternate_email),
            title: Text(l.t('set_username')),
            subtitle: Text(_username == null ? l.t('set_username_hint') : '@$_username'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _editUsername,
          ),
          // Referidos: solo en el panel de empresa (el chófer no paga, lo paga
          // la empresa).
          if (isOwner)
            ListTile(
              leading: const Icon(Icons.emoji_events, color: Colors.amber),
              title: Text(l.t('ch_title')),
              subtitle: Text(l.t('ch_settings_sub')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(const ChallengesScreen()),
            ),
          // Solo empresarios/autónomos con suscripción activa de pago (R-REF-01).
          if (isOwner && _subActive)
            ListTile(
              leading: const Icon(Icons.card_giftcard, color: Colors.amber),
              title: Text(l.t('set_referral')),
              subtitle: Text(l.t('set_referral_sub')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(ReferralScreen(profile: widget.profile)),
            ),
          ListTile(
            leading: Badge(
              isLabelVisible: _newReply,
              child: const Icon(Icons.support_agent),
            ),
            title: Text(l.t('set_report_bug')),
            subtitle: Text(_newReply ? l.t('tk_new_reply') : l.t('set_report_bug_sub')),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openTickets,
          ),
          // Informe de error (Loop #6): unidireccional al equipo de TaxiCount
          // (admin) con copia al jefe. No es un chat ni va a "Mensajes al jefe".
          ListTile(
            leading: const Icon(Icons.bug_report_outlined, color: Colors.deepOrange),
            title: Text(l.t('set_report_error')),
            subtitle: Text(l.t('set_report_error_sub')),
            trailing: const Icon(Icons.chevron_right),
            onTap: _reportErrorDialog,
          ),
          // Panel de administrador de plataforma (solo admins).
          if (widget.profile.isAdmin)
            ListTile(
              leading: const Icon(Icons.shield, color: Colors.deepPurple),
              title: Text(l.t('admin_title')),
              subtitle: Text(l.t('admin_sub')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(const AdminScreen()),
            ),
          if (!isOwner && _vehicleCount > 1)
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
          GestureDetector(
            onTap: _editAvatar,
            child: Stack(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: Colors.amber,
                  backgroundImage: _avatarB64 != null ? MemoryImage(base64Decode(_avatarB64!)) : null,
                  child: _avatarB64 != null
                      ? null
                      : Icon(isOwner ? Icons.business : Icons.person, size: 30, color: Colors.white),
                ),
                Positioned(
                  right: 0, bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                    child: const Icon(Icons.camera_alt, size: 14, color: Colors.black54),
                  ),
                ),
              ],
            ),
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
          if (isOwner)
            IconButton(
              key: const Key('edit_company_button'),
              tooltip: l.t('set_edit_company'),
              icon: const Icon(Icons.edit),
              onPressed: _editCompanyName,
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
                if (_vehicleCount > 1)
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
