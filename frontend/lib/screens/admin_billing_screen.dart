import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import 'admin_company_detail_screen.dart';
import 'admin_theme.dart';

/// Módulo Facturación del panel rediseñado (Fase 3): visión de negocio lado
/// TaxiCount. Estándar SaaS: arriba SALUD recurrente (MRR/ARR real de Stripe,
/// churn), luego CAJA real cobrada con selector Hoy/Mes/Total, y las colas de
/// acción (impagados, pruebas). Cada fila abre la ficha. Nunca finanzas del
/// cliente (solo NUESTROS ingresos).
class AdminBillingScreen extends StatefulWidget {
  const AdminBillingScreen({super.key});

  @override
  State<AdminBillingScreen> createState() => _AdminBillingScreenState();
}

// Periodo de la caja real cobrada.
enum _CashPeriod { today, mtd, total }

// Orden de la lista de empresas que pagan.
enum _BillSort { paid, seats, name }

class _AdminBillingScreenState extends State<AdminBillingScreen> {
  final _service = DataService();
  late Future<Map<String, dynamic>> _future = _service.adminBilling();
  _CashPeriod _period = _CashPeriod.mtd;
  _BillSort _sort = _BillSort.paid;

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
        appBar: adminAppBar(l.t('adm_mod_billing'), actions: [
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
            final daysCh = (t['free_days_challenges'] as num?)?.toInt() ?? 0;
            final daysRef = (t['free_days_referrals'] as num?)?.toInt() ?? 0;
            final sortedPaying = _sortPaying(paying);

            String eur(Object? v) =>
                '${(v as num?)?.toStringAsFixed(2) ?? '0'}€';

            return adminConstrained(RefreshIndicator(
              color: AdminColors.teal,
              backgroundColor: AdminColors.card,
              onRefresh: () async => _reload(),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: [
                  // ── SALUD recurrente (estándar SaaS: MRR/ARR + churn) ──
                  Row(
                    children: [
                      _kpiTile(
                          l.t('adm_bill_mrr'),
                          eur(t['mrr']),
                          '${l.t('adm_bill_arr')} ${eur(t['arr'])}',
                          AdminColors.teal),
                      const SizedBox(width: 7),
                      _kpiTile(
                          l.t('adm_co_paying'),
                          '${t['paying'] ?? 0}',
                          '${l.t('adm_bill_arpa')} ${eur(t['arpa'])}',
                          AdminColors.blue),
                      const SizedBox(width: 7),
                      _kpiTile(
                          l.t('adm_bill_churn'),
                          '${(t['churn'] as num?)?.toStringAsFixed(1) ?? '0'}%',
                          '${t['canceled'] ?? 0} ${l.t('adm_bill_canceled').toLowerCase()}',
                          AdminColors.red),
                    ],
                  ),
                  // ── CAJA real cobrada, con selector de periodo ──
                  adminSectionTitle(l.t('adm_bill_cash'),
                      color: AdminColors.teal, trailing: _periodPills(l)),
                  _cashCard(l, t),
                  // ── Colas de acción (glance) ──
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _kpiTile(l.t('adm_bill_pastdue'), '${t['past_due'] ?? 0}',
                          '', AdminColors.red),
                      const SizedBox(width: 7),
                      _kpiTile(l.t('adm_kpi_trials'), '${t['trialing'] ?? 0}',
                          '', AdminColors.amber),
                      const SizedBox(width: 7),
                      _kpiTile(
                          l.t('adm_kpi_freedays'),
                          l.t('fd_days', {
                            'n':
                                '${(t['free_days_total'] as num?)?.toInt() ?? 0}'
                          }),
                          '${l.t('sav_challenges')} $daysCh · ${l.t('sav_referrals')} $daysRef',
                          AdminColors.purple),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const _CouponManager(),
                  if (pastDue.isNotEmpty) ...[
                    adminSectionTitle(l.t('adm_bill_pastdue'),
                        color: AdminColors.red),
                    adminRowsCard([
                      for (final r in pastDue)
                        _companyRow(l, r,
                            trailing: eur(r['paid_total']),
                            trailingColor: AdminColors.red),
                    ]),
                  ],
                  if (trials.isNotEmpty) ...[
                    adminSectionTitle(l.t('adm_bill_sec_trials'),
                        color: AdminColors.amber),
                    adminRowsCard([
                      for (final r in trials)
                        _companyRow(l, r,
                            trailing: l.t('adm_bill_days_left',
                                {'n': '${r['trial_days_left']}'}),
                            trailingColor: AdminColors.amber),
                    ]),
                  ],
                  adminSectionTitle(l.t('adm_bill_sec_paying'),
                      color: AdminColors.teal,
                      trailing: sortedPaying.isEmpty ? null : _sortButton(l)),
                  if (sortedPaying.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Center(
                        child: Text(l.t('adm_bill_none'),
                            style: const TextStyle(
                                fontSize: 12, color: AdminColors.muted)),
                      ),
                    )
                  else
                    adminRowsCard([
                      for (final r in sortedPaying)
                        _companyRow(l, r,
                            trailing: eur(r['paid_total']),
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

  // KPI del kit, en 3 columnas iguales.
  Widget _kpiTile(String label, String value, String sub, Color color) =>
      Expanded(
        child: AdminKpiTile(label: label, value: value, sub: sub, color: color),
      );

  // Selector de periodo de la caja (Hoy / Mes / Total).
  Widget _periodPills(AppLocalizations l) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (p, lbl) in [
            (_CashPeriod.today, l.t('adm_bill_today')),
            (_CashPeriod.mtd, l.t('adm_bill_month')),
            (_CashPeriod.total, l.t('adm_bill_total')),
          ])
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: AdminPill(
                  label: lbl,
                  selected: _period == p,
                  color: AdminColors.teal,
                  onTap: () => setState(() => _period = p)),
            ),
        ],
      );

  // Tarjeta con la caja real cobrada del periodo elegido.
  Widget _cashCard(AppLocalizations l, Map<String, dynamic> t) {
    final (value, note) = switch (_period) {
      _CashPeriod.today => (t['cash_today'], l.t('adm_bill_today')),
      _CashPeriod.mtd => (t['cash_mtd'], l.t('adm_bill_month')),
      _CashPeriod.total => (t['cash_total'], l.t('adm_bill_total')),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: adminCardBox(),
      child: Row(
        children: [
          const Icon(Icons.payments, size: 18, color: AdminColors.teal),
          const SizedBox(width: 10),
          Expanded(
            child: Text(l.t('adm_bill_cash_sub'),
                style: const TextStyle(
                    fontSize: 10.5, color: AdminColors.secondary)),
          ),
          Text('${(value as num?)?.toStringAsFixed(2) ?? '0'}€',
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AdminColors.text)),
          const SizedBox(width: 6),
          Text(note.toUpperCase(),
              style: const TextStyle(fontSize: 8.5, color: AdminColors.muted)),
        ],
      ),
    );
  }

  List<Map<String, dynamic>> _sortPaying(List<Map<String, dynamic>> rows) {
    final out = [...rows];
    num paid(Map<String, dynamic> r) => (r['paid_total'] as num?) ?? 0;
    num seats(Map<String, dynamic> r) =>
        (r['paid_seats'] as num?) ?? (r['active_seats'] as num?) ?? 0;
    switch (_sort) {
      case _BillSort.paid:
        out.sort((a, b) => paid(b).compareTo(paid(a)));
      case _BillSort.seats:
        out.sort((a, b) => seats(b).compareTo(seats(a)));
      case _BillSort.name:
        out.sort((a, b) => '${a['name']}'
            .toLowerCase()
            .compareTo('${b['name']}'.toLowerCase()));
    }
    return out;
  }

  Widget _sortButton(AppLocalizations l) {
    String label(_BillSort s) => switch (s) {
          _BillSort.paid => l.t('adm_bill_sort_paid'),
          _BillSort.seats => l.t('adm_kpi_seats'),
          _BillSort.name => l.t('adm_co_sort_name'),
        };
    return PopupMenuButton<_BillSort>(
      initialValue: _sort,
      tooltip: l.t('adm_co_sort'),
      onSelected: (s) => setState(() => _sort = s),
      itemBuilder: (ctx) => [
        for (final s in _BillSort.values)
          PopupMenuItem(value: s, child: Text(label(s))),
      ],
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.swap_vert, size: 15, color: AdminColors.secondary),
        const SizedBox(width: 4),
        Text(label(_sort),
            style: const TextStyle(fontSize: 11, color: AdminColors.secondary)),
      ]),
    );
  }

  Widget _companyRow(AppLocalizations l, Map<String, dynamic> r,
      {required String trailing, required Color trailingColor}) {
    final name = (r['name'] as String?) ?? '—';
    final paidSeats = (r['paid_seats'] as num?)?.toInt();
    final activeSeats = (r['active_seats'] as num?)?.toInt() ?? 0;
    final freeDays = (r['free_days'] as num?)?.toInt() ?? 0;
    return AdminListRow(
      leading: AdminInitialsAvatar(name: name, size: 28),
      title: name,
      subtitle:
          '${paidSeats ?? activeSeats} ${l.t('adm_kpi_seats').toLowerCase()}'
          ' · ${l.t('adm_kpi_active', {'n': '$activeSeats'})}'
          '${freeDays > 0 ? ' · ${l.t('fd_days', {'n': '$freeDays'})}' : ''}',
      trailing: Text(trailing,
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600, color: trailingColor)),
      onTap: () => _openCompany(r),
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
  Map<String, dynamic>? _config; // todos los parámetros (para editar)
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final body = await _service.adminActiveCoupon();
      if (mounted) {
        setState(() {
          _coupon = (body?['coupon'] as Map?)?.cast<String, dynamic>();
          _config = (body?['config'] as Map?)?.cast<String, dynamic>();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  // Diálogo de crear/editar. Con `prefill` (config del cupón activo) queda como
  // "Editar": Stripe no deja mutar un cupón, así que al guardar se crea uno nuevo
  // con los parámetros y se retira el anterior (reemplazo).
  Future<void> _createDialog({Map<String, dynamic>? prefill}) async {
    final l = context.l10n;
    final editing = prefill != null;
    DateTime? parseD(Object? v) =>
        v == null ? null : DateTime.tryParse('$v')?.toLocal();
    final codeCtrl = TextEditingController(text: '${prefill?['code'] ?? ''}');
    final pctCtrl = TextEditingController(text: '${prefill?['pct'] ?? 50}');
    final maxCtrl = TextEditingController(
        text: prefill?['max_redemptions'] == null ? '' : '${prefill!['max_redemptions']}');
    final monthsCtrl = TextEditingController(
        text: '${prefill?['duration_in_months'] ?? 3}');
    String duration = (prefill?['duration'] as String?) ?? 'once';
    DateTime? startsAt = parseD(prefill?['starts_at']);
    DateTime? expiresAt = parseD(prefill?['expires_at']);
    String fmt(DateTime? d) => d == null
        ? '—'
        : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    final result = await showAdminDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(l.t(editing ? 'adm_coup_edit' : 'adm_coup_new')),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (editing) ...[
                      Text(l.t('adm_coup_edit_note'),
                          style: const TextStyle(
                              fontSize: 11, color: AdminColors.muted)),
                      const SizedBox(height: 8),
                    ],
                    TextField(
                        controller: codeCtrl,
                        autofocus: true,
                        textCapitalization: TextCapitalization.characters,
                        decoration: InputDecoration(
                            labelText: l.t('adm_coup_code'), isDense: true)),
                    const SizedBox(height: 8),
                    TextField(
                        controller: pctCtrl,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                            labelText: l.t('adm_coup_pct'),
                            suffixText: '%',
                            isDense: true)),
                    const SizedBox(height: 12),
                    Text(l.t('adm_coup_duration'),
                        style: const TextStyle(
                            fontSize: 12, color: AdminColors.muted)),
                    const SizedBox(height: 4),
                    Wrap(spacing: 6, children: [
                      for (final (v, lbl) in [
                        ('once', l.t('adm_coup_dur_once')),
                        ('repeating', l.t('adm_coup_dur_repeating')),
                        ('forever', l.t('adm_coup_dur_forever')),
                      ])
                        ChoiceChip(
                            label:
                                Text(lbl, style: const TextStyle(fontSize: 12)),
                            selected: duration == v,
                            onSelected: (_) => setLocal(() => duration = v)),
                    ]),
                    if (duration == 'repeating') ...[
                      const SizedBox(height: 8),
                      TextField(
                          controller: monthsCtrl,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                              labelText: l.t('adm_coup_months'),
                              isDense: true)),
                    ],
                    const SizedBox(height: 8),
                    TextField(
                        controller: maxCtrl,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                            labelText: l.t('adm_coup_max'),
                            isDense: true,
                            hintText: '∞')),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(l.t('adm_coup_max_help'),
                          style: const TextStyle(
                              fontSize: 11, color: AdminColors.muted)),
                    ),
                    const SizedBox(height: 8),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(l.t('adm_coup_starts'),
                          style: const TextStyle(fontSize: 13)),
                      subtitle: Text(fmt(startsAt),
                          style: const TextStyle(fontSize: 12)),
                      trailing: const Icon(Icons.event, size: 18),
                      onTap: () async {
                        final d = await showDatePicker(
                            context: ctx,
                            initialDate: DateTime.now(),
                            firstDate: DateTime.now(),
                            lastDate: DateTime(2100));
                        if (d != null) setLocal(() => startsAt = d);
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(l.t('adm_coup_expires'),
                          style: const TextStyle(fontSize: 13)),
                      subtitle: Text(fmt(expiresAt),
                          style: const TextStyle(fontSize: 12)),
                      trailing: const Icon(Icons.event_busy, size: 18),
                      onTap: () async {
                        final d = await showDatePicker(
                            context: ctx,
                            initialDate:
                                DateTime.now().add(const Duration(days: 30)),
                            firstDate: DateTime.now(),
                            lastDate: DateTime(2100));
                        if (d != null) setLocal(() => expiresAt = d);
                      },
                    ),
                  ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(l.t('cancel'))),
            FilledButton(
              onPressed: () {
                final code = codeCtrl.text.trim().toUpperCase();
                final pct = int.tryParse(pctCtrl.text.trim()) ?? 0;
                if (code.isEmpty || pct <= 0 || pct > 100) return;
                Navigator.pop(ctx, {
                  'code': code,
                  'pct': pct,
                  'duration': duration,
                  'months': int.tryParse(monthsCtrl.text.trim()),
                  'max': int.tryParse(maxCtrl.text.trim()),
                  'starts': startsAt?.toUtc().toIso8601String(),
                  'expires': expiresAt?.toUtc().toIso8601String(),
                });
              },
              child: Text(l.t('adm_coup_create')),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    setState(() => _busy = true);
    try {
      await _service.adminCreateCoupon(
        code: result['code'] as String,
        pct: result['pct'] as int,
        duration: result['duration'] as String,
        durationInMonths:
            result['duration'] == 'repeating' ? result['months'] as int? : null,
        maxRedemptions: result['max'] as int?,
        startsAt: result['starts'] as String?,
        expiresAt: result['expires'] as String?,
      );
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.t('adm_coup_created'))));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', ''))));
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', ''))));
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
          Expanded(
              child: Text(l.t('adm_coup_title'),
                  style: const TextStyle(
                      fontSize: 11, color: AdminColors.secondary))),
          if (_busy || _loading)
            const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
          else
            TextButton(
                onPressed: _createDialog, child: Text(l.t('adm_coup_new'))),
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
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: (c != null &&
                            (c['code'] as String?)?.isNotEmpty == true)
                        ? AdminColors.text
                        : AdminColors.muted),
              ),
            ),
            if (c != null &&
                (c['code'] as String?)?.isNotEmpty == true &&
                !_busy) ...[
              TextButton(
                  onPressed: () => _createDialog(prefill: _config ?? c),
                  child: Text(l.t('edit'))),
              TextButton(
                  onPressed: _deactivate,
                  child: Text(l.t('adm_coup_deactivate'))),
            ],
          ]),
      ]),
    );
  }
}
