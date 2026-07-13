import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import 'admin_company_detail_screen.dart';
import 'admin_theme.dart';

/// Módulo Facturación del panel rediseñado (Fase 3): visión de negocio lado
/// TaxiCount — MRR estimado, impagados, pruebas que acaban y ahorro repartido.
/// Cada fila abre la ficha de la empresa. Nunca muestra finanzas del cliente.
class AdminBillingScreen extends StatefulWidget {
  const AdminBillingScreen({super.key});

  @override
  State<AdminBillingScreen> createState() => _AdminBillingScreenState();
}

class _AdminBillingScreenState extends State<AdminBillingScreen> {
  final _service = DataService();
  late Future<Map<String, dynamic>> _future = _service.adminBilling();

  void _reload() => setState(() => _future = _service.adminBilling());

  Future<void> _openCompany(Map<String, dynamic> r) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AdminCompanyDetailScreen(
          tenantId: r['id'] as String,
          tenantName: (r['name'] as String?) ?? '—'),
    ));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Theme(
      data: adminDarkTheme(),
      child: Scaffold(
        backgroundColor: AdminColors.bg,
        appBar: AppBar(
          backgroundColor: AdminColors.bg,
          foregroundColor: AdminColors.text,
          elevation: 0,
          title: Text(l.t('adm_mod_billing'),
              style: const TextStyle(fontSize: 16, color: AdminColors.text)),
          actions: [
            IconButton(
                tooltip: l.t('refresh'),
                icon: const Icon(Icons.refresh,
                    size: 20, color: AdminColors.secondary),
                onPressed: _reload),
          ],
        ),
        body: FutureBuilder<Map<String, dynamic>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(
                  child: CircularProgressIndicator(color: AdminColors.teal));
            }
            if (snap.hasError) {
              return Center(
                  child: Text('${snap.error}',
                      style: const TextStyle(
                          color: AdminColors.red, fontSize: 13)));
            }
            final d = snap.data ?? {};
            final t = (d['totals'] as Map?)?.cast<String, dynamic>() ?? {};
            final pastDue =
                ((d['past_due'] as List?) ?? []).cast<Map<String, dynamic>>();
            final trials =
                ((d['trials'] as List?) ?? []).cast<Map<String, dynamic>>();
            final paying =
                ((d['paying'] as List?) ?? []).cast<Map<String, dynamic>>();
            final mrr = (t['mrr'] as num?)?.toDouble() ?? 0;
            final daysCh = (t['free_days_challenges'] as num?)?.toInt() ?? 0;
            final daysRef = (t['free_days_referrals'] as num?)?.toInt() ?? 0;

            return adminConstrained(RefreshIndicator(
              color: AdminColors.teal,
              backgroundColor: AdminColors.card,
              onRefresh: () async => _reload(),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: [
                  // KPIs (fila 1: negocio)
                  Row(
                    children: [
                      _kpi(l.t('adm_kpi_mrr'), '${mrr.toStringAsFixed(2)}€',
                          '${t['paying'] ?? 0} ${l.t('adm_co_paying').toLowerCase()}',
                          AdminColors.teal),
                      const SizedBox(width: 7),
                      _kpi(l.t('adm_bill_arpu'), '${(t['arpu'] as num?)?.toStringAsFixed(2) ?? '0'}€', '',
                          AdminColors.blue),
                      const SizedBox(width: 7),
                      _kpi(l.t('adm_bill_churn'), '${(t['churn'] as num?)?.toStringAsFixed(1) ?? '0'}%',
                          '${t['canceled'] ?? 0} ${l.t('adm_bill_canceled').toLowerCase()}',
                          AdminColors.red),
                    ],
                  ),
                  const SizedBox(height: 7),
                  // KPIs (fila 2: estado)
                  Row(
                    children: [
                      _kpi(l.t('adm_bill_pastdue'), '${t['past_due'] ?? 0}', '',
                          AdminColors.red),
                      const SizedBox(width: 7),
                      _kpi(l.t('adm_kpi_trials'), '${t['trialing'] ?? 0}', '',
                          AdminColors.amber),
                      const SizedBox(width: 7),
                      _kpi(l.t('adm_kpi_freedays'),
                          l.t('fd_days', {'n': '${(t['free_days_total'] as num?)?.toInt() ?? 0}'}),
                          '', AdminColors.teal),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Ahorro repartido (retos + referidos)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: AdminColors.teal.withValues(alpha: .28)),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.savings,
                            size: 16, color: AdminColors.teal),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(l.t('adm_bill_savings'),
                              style: const TextStyle(
                                  fontSize: 11, color: AdminColors.secondary)),
                        ),
                        Text(
                          l.t('fd_days', {'n': '${daysCh + daysRef}'}),
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600,
                              color: AdminColors.text),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${l.t('sav_challenges')} ${l.t('fd_days', {'n': '$daysCh'})} · '
                          '${l.t('sav_referrals')} ${l.t('fd_days', {'n': '$daysRef'})}',
                          style: const TextStyle(
                              fontSize: 9, color: AdminColors.muted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  const _CouponManager(),
                  if (pastDue.isNotEmpty) ...[
                    _sectionTitle(l.t('adm_bill_pastdue'), AdminColors.red),
                    _rowsCard([
                      for (final r in pastDue)
                        _companyRow(l, r,
                            trailing:
                                '${(r['mrr'] as num?)?.toStringAsFixed(2) ?? '0'}€',
                            trailingColor: AdminColors.red),
                    ]),
                  ],
                  if (trials.isNotEmpty) ...[
                    _sectionTitle(
                        l.t('adm_bill_sec_trials'), AdminColors.amber),
                    _rowsCard([
                      for (final r in trials)
                        _companyRow(l, r,
                            trailing: l.t('adm_bill_days_left',
                                {'n': '${r['trial_days_left']}'}),
                            trailingColor: AdminColors.amber),
                    ]),
                  ],
                  _sectionTitle(l.t('adm_bill_sec_paying'), AdminColors.teal),
                  if (paying.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Center(
                        child: Text(l.t('adm_bill_none'),
                            style: const TextStyle(
                                fontSize: 12, color: AdminColors.muted)),
                      ),
                    )
                  else
                    _rowsCard([
                      for (final r in paying)
                        _companyRow(l, r,
                            trailing:
                                '${(r['mrr'] as num?)?.toStringAsFixed(2) ?? '0'}€',
                            trailingColor: AdminColors.teal),
                    ]),
                ],
              ),
            ));
          },
        ),
      ),
    );
  }

  Widget _kpi(String label, String value, String sub, Color color) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(color: color.withValues(alpha: .28)),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label.toUpperCase(),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 8.5, letterSpacing: 1.1, color: color)),
              const SizedBox(height: 2),
              Text(value,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600,
                      color: AdminColors.text)),
              if (sub.isNotEmpty)
                Text(sub,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 9, color: AdminColors.muted)),
            ],
          ),
        ),
      );

  Widget _sectionTitle(String text, Color color) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Row(
          children: [
            Container(
                width: 7, height: 7,
                decoration:
                    BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 7),
            Text(text.toUpperCase(),
                style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600,
                    letterSpacing: 1.5, color: AdminColors.text)),
          ],
        ),
      );

  Widget _rowsCard(List<Widget> rows) => Container(
        decoration: BoxDecoration(
            color: AdminColors.card, borderRadius: BorderRadius.circular(12)),
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const Divider(height: 1, color: AdminColors.hairline),
              rows[i],
            ],
          ],
        ),
      );

  Widget _companyRow(AppLocalizations l, Map<String, dynamic> r,
      {required String trailing, required Color trailingColor}) {
    final name = (r['name'] as String?) ?? '—';
    final seats = (r['seats'] as num?)?.toInt() ?? 1;
    final freeDays = (r['free_days'] as num?)?.toInt() ?? 0;
    return InkWell(
      onTap: () => _openCompany(r),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            AdminInitialsAvatar(name: name, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w500,
                          color: AdminColors.text)),
                  Text(
                    '$seats ${l.t('adm_kpi_seats').toLowerCase()}'
                    '${freeDays > 0 ? ' · ${l.t('fd_days', {'n': '$freeDays'})}' : ''}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 10, color: AdminColors.muted),
                  ),
                ],
              ),
            ),
            Text(trailing,
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600,
                    color: trailingColor)),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right,
                size: 15, color: AdminColors.muted),
          ],
        ),
      ),
    );
  }
}

// Gestión del cupón activo (Facturación): muestra el cupón vigente y permite
// crear uno nuevo que se replica en Stripe (coupon + promotion code) y queda
// como activo. También permite desactivarlo (sin cupón => no se muestra aviso).
class _CouponManager extends StatefulWidget {
  const _CouponManager();
  @override
  State<_CouponManager> createState() => _CouponManagerState();
}

class _CouponManagerState extends State<_CouponManager> {
  final _service = DataService();
  Map<String, dynamic>? _coupon;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await _service.adminActiveCoupon();
      if (mounted) setState(() { _coupon = c; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createDialog() async {
    final l = context.l10n;
    final codeCtrl = TextEditingController();
    final pctCtrl = TextEditingController(text: '50');
    final result = await showAdminDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('adm_coup_new')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: codeCtrl, autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(labelText: l.t('adm_coup_code'), isDense: true)),
          const SizedBox(height: 8),
          TextField(controller: pctCtrl, keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: l.t('adm_coup_pct'), suffixText: '%', isDense: true)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.t('cancel'))),
          FilledButton(
            onPressed: () {
              final code = codeCtrl.text.trim().toUpperCase();
              final pct = int.tryParse(pctCtrl.text.trim()) ?? 0;
              if (code.isEmpty || pct <= 0 || pct > 100) return;
              Navigator.pop(ctx, {'code': code, 'pct': pct});
            },
            child: Text(l.t('adm_coup_create')),
          ),
        ],
      ),
    );
    if (result == null) return;
    setState(() => _busy = true);
    try {
      await _service.adminCreateCoupon(code: result['code'] as String, pct: result['pct'] as int);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('adm_coup_created'))));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deactivate() async {
    setState(() => _busy = true);
    try {
      await _service.adminSetActiveCoupon(code: '');
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = _coupon;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: AdminColors.purple.withValues(alpha: .3)),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.local_offer, size: 16, color: AdminColors.purple),
          const SizedBox(width: 8),
          Expanded(child: Text(l.t('adm_coup_title'),
              style: const TextStyle(fontSize: 11, color: AdminColors.secondary))),
          if (_busy || _loading)
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          else
            TextButton(onPressed: _createDialog, child: Text(l.t('adm_coup_new'))),
        ]),
        const SizedBox(height: 6),
        if (!_loading)
          Row(children: [
            Expanded(
              child: Text(
                (c != null && (c['code'] as String?)?.isNotEmpty == true)
                    ? '${c['code']} · ${c['pct']}%'
                    : l.t('adm_coup_none'),
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600,
                    color: (c != null && (c['code'] as String?)?.isNotEmpty == true)
                        ? AdminColors.text : AdminColors.muted),
              ),
            ),
            if (c != null && (c['code'] as String?)?.isNotEmpty == true && !_busy)
              TextButton(onPressed: _deactivate, child: Text(l.t('adm_coup_deactivate'))),
          ]),
      ]),
    );
  }
}
