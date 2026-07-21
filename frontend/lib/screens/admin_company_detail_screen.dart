import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import 'admin_incident_chat_screen.dart';
import 'admin_theme.dart';

/// Ficha de empresa del panel rediseñado (Fase 2). Porta TODA la funcionalidad
/// del AdminCompanyScreen clásico (suscripción, usuarios, vehículos e
/// incidencias) a la estética "eléctrica": cabecera con chips de estado, KPIs
/// de suscripción (lado TaxiCount, nunca finanzas del cliente), pestañas
/// píldora y zona sensible con doble confirmación (escribir el nombre).
class AdminCompanyDetailScreen extends StatefulWidget {
  final String tenantId;
  final String tenantName;
  const AdminCompanyDetailScreen(
      {super.key, required this.tenantId, required this.tenantName});

  @override
  State<AdminCompanyDetailScreen> createState() =>
      _AdminCompanyDetailScreenState();
}

class _AdminCompanyDetailScreenState extends State<AdminCompanyDetailScreen> {
  final _service = DataService();
  late Future<Map<String, dynamic>> _future =
      _service.adminCompany(widget.tenantId);
  int _tab = 0; // 0 resumen · 1 usuarios · 2 vehículos · 3 incidencias
  bool _busy = false; // operación en curso (reactivar, etc.)
  // "Modo soporte": por defecto la ficha es de SUPERVISIÓN (solo lectura de la
  // operativa del cliente: conductores y vehículos). Al activarlo se revelan las
  // acciones operativas, que YA quedan registradas en admin_actions_log
  // (Auditoría). Separa el rol plataforma (nosotros) del rol operador (el jefe).
  bool _support = false;

  void _reload() =>
      setState(() => _future = _service.adminCompany(widget.tenantId));

  Future<void> _toast(String msg) async {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
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
    return Theme(
      data: adminDarkTheme(),
      child: Scaffold(
        backgroundColor: AdminColors.bg,
        appBar: adminAppBar(widget.tenantName, actions: [
          IconButton(
            tooltip: l.t('adm_support_mode'),
            icon: Icon(
                _support ? Icons.build_circle : Icons.build_circle_outlined,
                size: 20,
                color: _support ? AdminColors.amber : AdminColors.secondary),
            onPressed: () => setState(() => _support = !_support),
          ),
          IconButton(
              tooltip: l.t('refresh'),
              icon: const Icon(Icons.refresh,
                  size: 20, color: AdminColors.secondary),
              onPressed: _reload),
        ]),
        body: FutureBuilder<Map<String, dynamic>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(
                  child: CircularProgressIndicator(color: AdminColors.teal));
            }
            if (snap.hasError) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${snap.error}',
                        style: const TextStyle(
                            color: AdminColors.red, fontSize: 13)),
                    const SizedBox(height: 12),
                    OutlinedButton(
                        onPressed: _reload, child: Text(l.t('retry'))),
                  ],
                ),
              );
            }
            final data = snap.data ?? {};
            final tenant =
                (data['tenant'] as Map?)?.cast<String, dynamic>() ?? {};
            final users =
                ((data['users'] as List?) ?? []).cast<Map<String, dynamic>>();
            final counts =
                (data['counts'] as Map?)?.cast<String, dynamic>() ?? {};
            final vehicles = ((data['vehicles_list'] as List?) ?? [])
                .cast<Map<String, dynamic>>();
            final incidents = ((data['incidents_list'] as List?) ?? [])
                .cast<Map<String, dynamic>>();
            final billing =
                (data['billing'] as Map?)?.cast<String, dynamic>() ?? {};

            return adminConstrained(ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                _header(l, tenant, users),
                if (_support) ...[
                  const SizedBox(height: 10),
                  _supportBanner(l),
                ],
                const SizedBox(height: 12),
                _kpiStrip(l, tenant, billing),
                const SizedBox(height: 12),
                _pillTabs(l, users.length, vehicles.length, incidents.length),
                const SizedBox(height: 10),
                switch (_tab) {
                  1 => _usersTab(l, users, vehicles),
                  2 => _vehiclesTab(l, vehicles),
                  3 => _incidentsTab(l, incidents),
                  _ => _summaryTab(l, tenant, counts),
                },
              ],
            ));
          },
        ),
      ),
    );
  }

  // ===================== Cabecera =====================
  Widget _header(AppLocalizations l, Map<String, dynamic> t,
      List<Map<String, dynamic>> users) {
    final owner = users.where((u) => u['role'] == 'owner').toList();
    final ownerMail =
        owner.isNotEmpty ? (owner.first['email'] as String? ?? '') : '';
    final trialEnds = DateTime.tryParse('${t['trial_ends_at']}');
    final trialLeft = (trialEnds != null && trialEnds.isAfter(DateTime.now()))
        ? trialEnds.difference(DateTime.now()).inDays + 1
        : 0;
    return Row(
      children: [
        AdminInitialsAvatar(name: widget.tenantName, size: 38),
        const SizedBox(width: 10),
        // El nombre ya está en la barra superior; aquí, el contacto del owner.
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ownerMail.isNotEmpty ? ownerMail : '—',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AdminColors.text)),
              Text(l.t('admin_role_owner'),
                  style:
                      const TextStyle(fontSize: 10, color: AdminColors.muted)),
            ],
          ),
        ),
        AdminStatusChip(
            status: t['subscription_status'] as String?,
            trialDaysLeft: trialLeft),
      ],
    );
  }

  // Aviso visible mientras el modo soporte está activo: recuerda que actuar
  // sobre la operativa del cliente queda registrado en Auditoría.
  Widget _supportBanner(AppLocalizations l) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: AdminColors.amber.withValues(alpha: .10),
          border: Border.all(color: AdminColors.amber.withValues(alpha: .5)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const Icon(Icons.build_circle, size: 15, color: AdminColors.amber),
            const SizedBox(width: 8),
            Expanded(
              child: Text(l.t('adm_support_on'),
                  style: const TextStyle(
                      fontSize: 10.5, color: AdminColors.amber, height: 1.3)),
            ),
          ],
        ),
      );

  // Pista de solo-lectura en las pestañas operativas cuando NO hay modo soporte.
  Widget _readonlyHint(AppLocalizations l) => Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 2),
        child: Row(
          children: [
            const Icon(Icons.lock_outline, size: 12, color: AdminColors.muted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(l.t('adm_readonly_hint'),
                  style:
                      const TextStyle(fontSize: 10, color: AdminColors.muted)),
            ),
          ],
        ),
      );

  // ===================== KPIs de suscripción =====================
  Widget _kpiStrip(AppLocalizations l, Map<String, dynamic> t,
      Map<String, dynamic> billing) {
    final freeDays = (billing['free_days'] as num?)?.toInt() ?? 0;
    final seats = (billing['active_drivers'] as num?)?.toInt() ?? 0;
    final paidTotal = (billing['paid_total'] as num?)?.toDouble() ?? 0;
    final couponTotal = (billing['coupon_total'] as num?)?.toDouble() ?? 0;
    final refundTotal = (billing['refund_total'] as num?)?.toDouble() ?? 0;
    final limit = t['drivers_limit'];
    final created = DateTime.tryParse('${t['created_at']}')?.toLocal();
    final since = created == null
        ? '—'
        : '${created.month.toString().padLeft(2, '0')}/${created.year % 100}';

    Widget tile(String label, String value, Color color) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            decoration: BoxDecoration(
              border: Border.all(color: color.withValues(alpha: .28)),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 8, letterSpacing: 1.1, color: color)),
                const SizedBox(height: 2),
                Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AdminColors.text)),
              ],
            ),
          ),
        );

    String eur(double v) => '${v.toStringAsFixed(2).replaceAll('.', ',')}€';
    return Column(
      children: [
        Row(
          children: [
            tile(l.t('adm_kpi_seats'),
                limit == null ? '$seats' : '$seats/$limit', AdminColors.blue),
            const SizedBox(width: 7),
            tile(l.t('adm_kpi_freedays'), l.t('fd_days', {'n': '$freeDays'}),
                AdminColors.teal),
            const SizedBox(width: 7),
            tile(l.t('adm_kpi_since'), since, AdminColors.purple),
          ],
        ),
        const SizedBox(height: 7),
        // Lo que ESTA empresa nos ha pagado realmente (Stripe) y cuánto se le
        // ha descontado con cupones. No son sus finanzas internas (sus carreras).
        Row(
          children: [
            tile(l.t('adm_kpi_paid_total'), eur(paidTotal), AdminColors.teal),
            const SizedBox(width: 7),
            tile(l.t('adm_kpi_coupons'), eur(couponTotal), AdminColors.amber),
            if (refundTotal > 0) ...[
              const SizedBox(width: 7),
              tile(l.t('adm_kpi_refunds'), eur(refundTotal), AdminColors.red),
            ],
          ],
        ),
      ],
    );
  }

  // ===================== Pestañas píldora =====================
  Widget _pillTabs(AppLocalizations l, int nUsers, int nVehicles, int nInc) {
    final labels = [
      l.t('admin_tab_summary'),
      '${l.t('admin_tab_drivers')} · $nUsers',
      '${l.t('admin_tab_vehicles')} · $nVehicles',
      '${l.t('admin_tab_incidents')} · $nInc',
    ];
    return SizedBox(
      height: 32,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (var i = 0; i < labels.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: InkWell(
                onTap: () => setState(() => _tab = i),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: _tab == i ? AdminColors.purple : Colors.transparent,
                    border: Border.all(
                        color: _tab == i
                            ? AdminColors.purple
                            : AdminColors.hairline),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(labels[i],
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight:
                            _tab == i ? FontWeight.w600 : FontWeight.w400,
                        color:
                            _tab == i ? AdminColors.bg : AdminColors.secondary,
                      )),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ===================== TAB Resumen =====================
  Widget _summaryTab(
      AppLocalizations l, Map<String, dynamic> t, Map<String, dynamic> counts) {
    final created = DateTime.tryParse('${t['created_at']}')?.toLocal();
    final daysUsing =
        created == null ? '—' : '${DateTime.now().difference(created).inDays}';
    final trialEnds = DateTime.tryParse('${t['trial_ends_at']}')?.toLocal();
    final trialLeft = (trialEnds != null && DateTime.now().isBefore(trialEnds))
        ? trialEnds.difference(DateTime.now()).inDays + 1
        : 0;
    final solo = t['solo'] == true;
    final status = (t['subscription_status'] as String?) ?? 'inactive';

    Widget row(String k, String v, {IconData? action, VoidCallback? onTap}) =>
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Expanded(
                    child: Text(k,
                        style: const TextStyle(
                            fontSize: 11, color: AdminColors.secondary))),
                Text(v,
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: AdminColors.text)),
                if (action != null) ...[
                  const SizedBox(width: 8),
                  Icon(action, size: 14, color: AdminColors.purple),
                ],
              ],
            ),
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        adminRowsCard([
          row(l.t('admin_mode_solo'),
              solo ? l.t('admin_mode_solo') : l.t('admin_mode_fleet')),
          row(l.t('admin_status'), adminStatusLabel(l, status),
              action: Icons.edit, onTap: () => _editSubscription(l, t)),
          row(l.t('admin_days_using'), daysUsing),
          row(l.t('admin_trial_left'),
              trialLeft > 0 ? '$trialLeft' : l.t('admin_trial_over')),
          if ((t['join_code'] as String?)?.isNotEmpty == true)
            row(l.t('admin_join_code'), '${t['join_code']}'),
          if ((t['stripe_customer_id'] as String?)?.isNotEmpty == true)
            row('Stripe', l.t('admin_has_stripe')),
        ]),
        const SizedBox(height: 10),
        // Recuentos (las finanzas del cliente siguen enmascaradas).
        Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: adminCardBox(),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _stat('${counts['vehicles'] ?? 0}', l.t('nav_vehicles')),
              _stat(
                  '${counts['transactions'] ?? 0}', l.t('admin_transactions')),
              _stat('${counts['incidents'] ?? 0}', l.t('admin_incidents')),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            const Icon(Icons.lock_outline, size: 12, color: AdminColors.muted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(l.t('admin_financials_masked'),
                  style:
                      const TextStyle(fontSize: 10, color: AdminColors.muted)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // Acción de soporte/pruebas: reinicia el cupón de bienvenida (borra
        // coupon_redeemed_code) para que la empresa vuelva a ver el aviso.
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(
                foregroundColor: AdminColors.secondary,
                visualDensity: VisualDensity.compact),
            icon: const Icon(Icons.restart_alt, size: 15),
            label: Text(l.t('adm_reset_welcome'),
                style: const TextStyle(fontSize: 11)),
            onPressed: _resetWelcomeCoupon,
          ),
        ),
        const SizedBox(height: 8),
        _dangerZone(l, status, t['closed_at'] != null),
      ],
    );
  }

  Future<void> _resetWelcomeCoupon() async {
    final l = context.l10n;
    final ok = await showAdminDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('adm_reset_welcome')),
        content: Text(l.t('adm_reset_welcome_confirm')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.t('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.t('adm_reset_welcome'))),
        ],
      ),
    );
    if (ok != true) return;
    await _guard(() => _service.adminResetWelcomeCoupon(widget.tenantId),
        l.t('adm_reset_welcome_done'));
  }

  Widget _stat(String v, String label) => Column(
        children: [
          Text(v,
              style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: AdminColors.text)),
          Text(label,
              style: const TextStyle(fontSize: 10, color: AdminColors.muted)),
        ],
      );

  // ===================== Zona sensible =====================
  Widget _dangerZone(AppLocalizations l, String status, bool closed) {
    final suspended = status == 'canceled';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: AdminColors.redBg),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber, size: 15, color: AdminColors.red),
              const SizedBox(width: 8),
              Text(l.t('adm_dz_title'),
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AdminColors.red)),
            ],
          ),
          const SizedBox(height: 4),
          Text(l.t('adm_dz_sub'),
              style: const TextStyle(fontSize: 10, color: AdminColors.muted)),
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor:
                      suspended ? AdminColors.teal : AdminColors.amber,
                  side: BorderSide(
                      color: (suspended ? AdminColors.teal : AdminColors.amber)
                          .withValues(alpha: .5)),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => _toggleSuspend(l, suspended),
                child: Text(
                    suspended
                        ? l.t('adm_dz_reactivate')
                        : l.t('adm_dz_suspend'),
                    style: const TextStyle(fontSize: 11)),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AdminColors.red,
                  side: BorderSide(
                      color: AdminColors.redSolid.withValues(alpha: .5)),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => _deleteCompany(l),
                child: Text(l.t('admin_delete_company'),
                    style: const TextStyle(fontSize: 11)),
              ),
            ],
          ),
          // Empresa YA dada de baja: reactivarla (deshace el cierre y recrea el
          // owner) o purgarla DEFINITIVAMENTE (borra todos sus datos).
          if (closed) ...[
            const SizedBox(height: 10),
            const Divider(height: 1, color: AdminColors.hairline),
            const SizedBox(height: 10),
            Text(l.t('adm_dz_react_sub'),
                style: const TextStyle(fontSize: 10, color: AdminColors.muted)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AdminColors.teal,
                side: BorderSide(color: AdminColors.teal.withValues(alpha: .5)),
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.restart_alt, size: 15),
              onPressed: _busy ? null : () => _reactivateCompany(l),
              label: Text(l.t('adm_dz_react'),
                  style: const TextStyle(fontSize: 11)),
            ),
            const SizedBox(height: 10),
            Text(l.t('adm_dz_purge_sub'),
                style: const TextStyle(fontSize: 10, color: AdminColors.muted)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AdminColors.red,
                side: BorderSide(
                    color: AdminColors.redSolid.withValues(alpha: .7)),
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.delete_forever, size: 15),
              onPressed: () => _purgeCompany(l),
              label: Text(l.t('adm_dz_purge'),
                  style: const TextStyle(fontSize: 11)),
            ),
          ],
        ],
      ),
    );
  }

  // REACTIVAR una empresa dada de baja: pide el nombre real (la baja lo
  // anonimizó), el correo del nuevo owner y los días de prueba; al confirmar,
  // muestra la contraseña temporal y el código de flota para dárselos al cliente.
  Future<void> _reactivateCompany(AppLocalizations l) async {
    final nameCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final daysCtrl = TextEditingController(text: '15');
    final ok = await showAdminDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('adm_dz_react')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.t('adm_react_help'), style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: InputDecoration(
                  labelText: l.t('adm_react_name'), isDense: true),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: emailCtrl,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                  labelText: l.t('adm_react_email'), isDense: true),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: daysCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                  labelText: l.t('adm_react_days'), isDense: true),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.t('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.t('adm_dz_react'))),
        ],
      ),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    final email = emailCtrl.text.trim();
    if (name.isEmpty || !email.contains('@')) {
      await _toast(l.t('adm_react_invalid'));
      return;
    }
    setState(() => _busy = true);
    try {
      final res = await _service.adminReactivateCompany(
        widget.tenantId,
        ownerEmail: email,
        companyName: name,
        trialDays: int.tryParse(daysCtrl.text.trim()) ?? 15,
      );
      _reload();
      if (!mounted) return;
      final temp = (res['tempPassword'] ?? '').toString();
      final code = (res['join_code'] ?? '').toString();
      final summary = '${l.t('adm_react_email')}: $email\n'
          '${l.t('adm_react_temp')}: $temp\n'
          '${l.t('adm_react_code')}: $code';
      await showAdminDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l.t('adm_react_done')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.t('adm_react_done_help'),
                  style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 10),
              SelectableText(summary, style: const TextStyle(fontSize: 13)),
            ],
          ),
          actions: [
            TextButton.icon(
              icon: const Icon(Icons.copy, size: 16),
              onPressed: () => Clipboard.setData(ClipboardData(text: summary)),
              label: Text(l.t('copy')),
            ),
            FilledButton(
                onPressed: () => Navigator.pop(ctx), child: Text(l.t('ok'))),
          ],
        ),
      );
    } catch (e) {
      await _toast('Error: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Purga DEFINITIVA con DOBLE confirmación: 1) escribir el nombre exacto,
  // 2) confirmación final irreversible.
  Future<void> _purgeCompany(AppLocalizations l) async {
    final ctrl = TextEditingController();
    final step1 = await showAdminDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(l.t('adm_dz_purge')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.t('adm_dz_purge_help'),
                  style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 10),
              Text(l.t('adm_dz_type_name'),
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                autofocus: true,
                onChanged: (_) => setLocal(() {}),
                decoration: InputDecoration(
                  hintText: widget.tenantName,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l.t('cancel'))),
            FilledButton(
              style:
                  FilledButton.styleFrom(backgroundColor: AdminColors.redSolid),
              onPressed: ctrl.text.trim() == widget.tenantName.trim()
                  ? () => Navigator.pop(ctx, true)
                  : null,
              child: Text(l.t('continue_btn')),
            ),
          ],
        ),
      ),
    );
    if (step1 != true) return;
    if (!mounted) return;
    // Segunda confirmación: última oportunidad, es irreversible.
    final step2 = await showAdminDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('adm_dz_purge_final_title')),
        content: Text(l.t('adm_dz_purge_final', {'name': widget.tenantName})),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.t('cancel'))),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: AdminColors.redSolid),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.t('adm_dz_purge')),
          ),
        ],
      ),
    );
    if (step2 != true) return;
    try {
      await _service.adminPurgeCompany(widget.tenantId);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      await _toast('Error: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  Future<void> _toggleSuspend(AppLocalizations l, bool suspended) async {
    if (!suspended) {
      final ok = await showAdminDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l.t('adm_dz_suspend')),
          content:
              Text(l.t('adm_dz_suspend_confirm', {'name': widget.tenantName})),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l.t('cancel'))),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l.t('adm_dz_suspend'))),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _guard(
        () => _service.adminUpdateCompany(widget.tenantId,
            {'subscription_status': suspended ? 'active' : 'canceled'}),
        l.t('saved'));
  }

  // Borrado con DOBLE confirmación: hay que escribir el nombre exacto.
  Future<void> _deleteCompany(AppLocalizations l) async {
    final ctrl = TextEditingController();
    final ok = await showAdminDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(l.t('admin_delete_company')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.t('admin_delete_company_help'),
                  style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 10),
              Text(l.t('adm_dz_type_name'),
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                key: const Key('delete_company_name_field'),
                controller: ctrl,
                autofocus: true,
                onChanged: (_) => setLocal(() {}),
                decoration: InputDecoration(
                  hintText: widget.tenantName,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l.t('cancel'))),
            FilledButton(
              style:
                  FilledButton.styleFrom(backgroundColor: AdminColors.redSolid),
              onPressed: ctrl.text.trim() == widget.tenantName.trim()
                  ? () => Navigator.pop(ctx, true)
                  : null,
              child: Text(l.t('admin_delete_confirm_btn')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (ctrl.text.trim() != widget.tenantName.trim()) {
      await _toast(l.t('adm_dz_name_mismatch'));
      return;
    }
    try {
      await _service.adminDeleteCompany(widget.tenantId);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      await _toast('Error: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  // ===================== Editar suscripción (portado) =====================
  Future<void> _editSubscription(
      AppLocalizations l, Map<String, dynamic> t) async {
    String status = (t['subscription_status'] as String?) ?? 'trialing';
    final extendCtrl = TextEditingController();
    final codeCtrl =
        TextEditingController(text: (t['join_code'] as String?) ?? '');
    const statuses = ['active', 'trialing', 'past_due', 'canceled', 'inactive'];

    final saved = await showAdminDialog<bool>(
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
                      DropdownMenuItem(
                          value: s,
                          child: Text('${adminStatusLabel(l, s)} ($s)')),
                  ],
                  onChanged: (v) => setLocal(() => status = v ?? status),
                ),
                const SizedBox(height: 6),
                // Los asientos (drivers_limit) = cantidad pagada en Stripe: se
                // gestionan desde Facturación (cobra y sincroniza). Aquí NO, para
                // no desincronizar la fuente de verdad.
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(l.t('adm_seats_in_billing'),
                      style: const TextStyle(
                          fontSize: 10.5, color: AdminColors.muted)),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: extendCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                      labelText: l.t('admin_extend_trial'),
                      hintText: l.t('admin_extend_hint')),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: codeCtrl,
                  textCapitalization: TextCapitalization.characters,
                  decoration:
                      InputDecoration(labelText: l.t('admin_join_code')),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l.t('cancel'))),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l.t('save'))),
          ],
        ),
      ),
    );
    if (saved != true) return;
    final patch = <String, dynamic>{
      'subscription_status': status,
      'join_code': codeCtrl.text.trim(),
    };
    // + añade días, - quita días de prueba.
    final extend = int.tryParse(extendCtrl.text.trim());
    if (extend != null && extend != 0) patch['extend_trial_days'] = extend;
    await _guard(() => _service.adminUpdateCompany(widget.tenantId, patch),
        l.t('saved'));
  }

  // ===================== TAB Usuarios (portado) =====================
  Widget _usersTab(AppLocalizations l, List<Map<String, dynamic>> users,
      List<Map<String, dynamic>> vehicles) {
    if (users.isEmpty) {
      return Center(
          child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(l.t('adm_no_results'),
            style: const TextStyle(fontSize: 12, color: AdminColors.muted)),
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!_support) _readonlyHint(l),
        adminRowsCard([for (final u in users) _userRow(l, u, vehicles)]),
      ],
    );
  }

  Widget _userRow(AppLocalizations l, Map<String, dynamic> u,
      List<Map<String, dynamic>> vehicles) {
    final email = (u['email'] as String?) ?? '—';
    final name = (u['name'] as String?) ?? '';
    final role = (u['role'] as String?) ?? 'driver';
    final active = u['active'] != false;
    final isAdmin = u['is_admin'] == true;
    final isOwner = role == 'owner';
    return InkWell(
      onTap: _support ? () => _assignVehiclesDialog(l, u, vehicles) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(isOwner ? Icons.badge : Icons.person,
                size: 18,
                color: active
                    ? (isOwner ? AdminColors.purple : AdminColors.blue)
                    : AdminColors.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name.isNotEmpty ? name : email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          color:
                              active ? AdminColors.text : AdminColors.muted)),
                  Text(
                    [
                      if (name.isNotEmpty) email,
                      isOwner
                          ? l.t('admin_role_owner')
                          : l.t('admin_role_driver'),
                      if (!active) l.t('admin_inactive'),
                      if (isAdmin) 'ADMIN',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(fontSize: 10, color: AdminColors.muted),
                  ),
                ],
              ),
            ),
            // Gestión operativa del equipo del cliente: solo en modo soporte
            // (auditada). Fuera de él, la ficha es de supervisión (solo lectura).
            if (_support)
              PopupMenuButton<String>(
                iconColor: AdminColors.secondary,
                onSelected: (v) {
                  if (v == 'vehicles') {
                    _assignVehiclesDialog(l, u, vehicles);
                  } else {
                    _onUserAction(l, u, v);
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                      value: 'vehicles',
                      child: Text(l.t('dr_assign_vehicles'))),
                  PopupMenuItem(
                      value: 'toggle_active',
                      child: Text(active
                          ? l.t('admin_deactivate')
                          : l.t('admin_activate'))),
                  PopupMenuItem(
                      value: 'toggle_admin',
                      child: Text(isAdmin
                          ? l.t('admin_remove_admin')
                          : l.t('admin_make_admin_short'))),
                  PopupMenuItem(
                      value: 'role',
                      child: Text(isOwner
                          ? l.t('admin_set_driver')
                          : l.t('admin_set_owner'))),
                  PopupMenuItem(
                      value: 'delete',
                      child: Text(l.t('admin_delete_user'),
                          style: const TextStyle(color: AdminColors.red))),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _assignVehiclesDialog(AppLocalizations l, Map<String, dynamic> u,
      List<Map<String, dynamic>> vehicles) async {
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
    final ok = await showAdminDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(
              l.t('dr_vehicles_of', {'name': (u['email'] as String?) ?? ''})),
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
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l.t('cancel'))),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l.t('save'))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _guard(() => _service.adminSetUserVehicles(userId, selected.toList()),
        l.t('saved'));
  }

  Future<void> _onUserAction(
      AppLocalizations l, Map<String, dynamic> u, String action) async {
    final id = u['id'] as String;
    switch (action) {
      case 'toggle_active':
        await _guard(
            () => _service
                .adminUpdateUser(id, {'active': !(u['active'] != false)}),
            l.t('saved'));
        break;
      case 'toggle_admin':
        await _guard(
            () => _service
                .adminUpdateUser(id, {'is_admin': !(u['is_admin'] == true)}),
            l.t('saved'));
        break;
      case 'role':
        final newRole = (u['role'] == 'owner') ? 'driver' : 'owner';
        // Cambiar el rol es delicado: confirmación explícita.
        final ok = await showAdminDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(newRole == 'owner'
                ? l.t('admin_set_owner')
                : l.t('admin_set_driver')),
            content: Text('${u['email']}'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(l.t('cancel'))),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(l.t('save'))),
            ],
          ),
        );
        if (ok != true) return;
        await _guard(() => _service.adminUpdateUser(id, {'role': newRole}),
            l.t('saved'));
        break;
      case 'delete':
        final ok = await showAdminDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l.t('admin_delete_user')),
            content: Text(
                l.t('admin_delete_user_confirm', {'email': '${u['email']}'})),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(l.t('cancel'))),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: AdminColors.redSolid),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l.t('admin_delete_confirm_btn')),
              ),
            ],
          ),
        );
        if (ok == true) {
          await _guard(
              () => _service.adminDeleteUser(id), l.t('admin_deleted'));
        }
        break;
    }
  }

  // ===================== TAB Vehículos (portado) =====================
  Widget _vehiclesTab(AppLocalizations l, List<Map<String, dynamic>> vehicles) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!_support) _readonlyHint(l),
        // Alta de vehículos = operativa del cliente: solo en modo soporte.
        if (_support) ...[
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AdminColors.teal,
                side: BorderSide(color: AdminColors.teal.withValues(alpha: .5)),
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.add, size: 15),
              label: Text(l.t('admin_add_vehicle'),
                  style: const TextStyle(fontSize: 11)),
              onPressed: () => _vehicleDialog(l),
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (vehicles.isEmpty)
          Center(
              child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l.t('admin_no_vehicles'),
                style: const TextStyle(fontSize: 12, color: AdminColors.muted)),
          ))
        else
          adminRowsCard([for (final v in vehicles) _vehicleRow(l, v)]),
      ],
    );
  }

  Widget _vehicleRow(AppLocalizations l, Map<String, dynamic> v) {
    final plate = (v['license_plate'] as String?) ?? '';
    final model = (v['model'] as String?) ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.directions_car, size: 18, color: AdminColors.blue),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(plate,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: AdminColors.text)),
                if (model.isNotEmpty)
                  Text(model,
                      style: const TextStyle(
                          fontSize: 10, color: AdminColors.muted)),
              ],
            ),
          ),
          if (_support)
            PopupMenuButton<String>(
              iconColor: AdminColors.secondary,
              onSelected: (a) {
                if (a == 'edit') {
                  _vehicleDialog(l, vehicle: v);
                } else if (a == 'delete') {
                  showAdminDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text(l.t('admin_delete_vehicle')),
                      content: Text('${l.t('admin_delete_vehicle')}: $plate?'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: Text(l.t('cancel'))),
                        FilledButton(
                          style: FilledButton.styleFrom(
                              backgroundColor: AdminColors.redSolid),
                          onPressed: () => Navigator.pop(ctx, true),
                          child: Text(l.t('admin_delete_confirm_btn')),
                        ),
                      ],
                    ),
                  ).then((ok) {
                    if (ok == true) {
                      _guard(
                          () => _service.adminDeleteVehicle(v['id'] as String),
                          l.t('admin_deleted'));
                    }
                  });
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'edit', child: Text(l.t('edit'))),
                PopupMenuItem(
                    value: 'delete',
                    child: Text(l.t('admin_delete_vehicle'),
                        style: const TextStyle(color: AdminColors.red))),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _vehicleDialog(AppLocalizations l,
      {Map<String, dynamic>? vehicle}) async {
    final plateCtrl = TextEditingController(
        text: (vehicle?['license_plate'] as String?) ?? '');
    final modelCtrl =
        TextEditingController(text: (vehicle?['model'] as String?) ?? '');
    final ok = await showAdminDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(vehicle == null ? l.t('admin_add_vehicle') : l.t('edit')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: plateCtrl,
                decoration:
                    InputDecoration(labelText: l.t('admin_vehicle_plate'))),
            const SizedBox(height: 8),
            TextField(
                controller: modelCtrl,
                decoration:
                    InputDecoration(labelText: l.t('admin_vehicle_model'))),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.t('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.t('save'))),
        ],
      ),
    );
    if (ok != true || plateCtrl.text.trim().isEmpty) return;
    if (vehicle == null) {
      await _guard(
          () => _service.adminAddVehicle(
              widget.tenantId, plateCtrl.text.trim(), modelCtrl.text.trim()),
          l.t('saved'));
    } else {
      await _guard(
          () => _service.adminUpdateVehicle(vehicle['id'] as String,
              plate: plateCtrl.text.trim(), model: modelCtrl.text.trim()),
          l.t('saved'));
    }
  }

  // ===================== TAB Incidencias (portado) =====================
  Widget _incidentsTab(
      AppLocalizations l, List<Map<String, dynamic>> incidents) {
    if (incidents.isEmpty) {
      return Center(
          child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(l.t('admin_no_incidents'),
            style: const TextStyle(fontSize: 12, color: AdminColors.muted)),
      ));
    }
    return adminRowsCard([for (final inc in incidents) _incidentRow(l, inc)]);
  }

  Widget _incidentRow(AppLocalizations l, Map<String, dynamic> inc) {
    final body = (inc['body'] as String?) ?? '';
    final status = (inc['status'] as String?) ?? 'abierta';
    final author = ((inc['users'] as Map?)?['email'] as String?) ?? '';
    final resolved = status == 'resuelta';
    // Solo llegan tickets de soporte (kind='app'); el backend ya filtra.
    return InkWell(
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => AdminIncidentChatScreen(incident: inc),
        ));
        _reload();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.bug_report, size: 17, color: AdminColors.coral),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: resolved ? AdminColors.muted : AdminColors.text,
                        decoration:
                            resolved ? TextDecoration.lineThrough : null,
                      )),
                  if (author.isNotEmpty)
                    Text(author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 10, color: AdminColors.muted)),
                ],
              ),
            ),
            IconButton(
              tooltip: resolved ? l.t('admin_reopen') : l.t('admin_resolve'),
              icon: Icon(resolved ? Icons.replay : Icons.check_circle,
                  size: 18,
                  color: resolved ? AdminColors.amber : AdminColors.teal),
              onPressed: () => _guard(
                () => _service.adminSetIncidentStatus(
                    inc['id'] as String, resolved ? 'abierta' : 'resuelta'),
                l.t('saved'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
