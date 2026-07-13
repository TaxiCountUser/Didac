import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import 'referral_screen.dart';

/// Clave i18n del estado de suscripción.
String subscriptionStatusKey(String? status) => switch (status) {
      'active' => 'st_active',
      'trialing' => 'st_trial',
      'past_due' => 'st_past_due',
      'canceled' => 'st_canceled',
      _ => 'st_inactive',
    };

/// Etiqueta legible del estado de suscripción.
String subscriptionStatusLabel(String? status) {
  switch (status) {
    case 'active':
      return 'Activa';
    case 'trialing':
      return 'Periodo de prueba';
    case 'past_due':
      return 'Pago pendiente';
    case 'canceled':
      return 'Cancelada';
    default:
      return 'Inactiva';
  }
}

Color subscriptionStatusColor(String? status) {
  switch (status) {
    case 'active':
    case 'trialing':
      return const Color(0xFF2E7D32);
    case 'past_due':
      return const Color(0xFFEF6C00);
    default:
      return const Color(0xFFC62828);
  }
}

bool subscriptionIsActive(String? status) => status == 'active' || status == 'trialing';

/// Pantalla de suscripción del Owner: plan actual, elegir/cambiar plan y portal.
class SubscriptionScreen extends StatefulWidget {
  final Profile profile;
  const SubscriptionScreen({super.key, required this.profile});

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  final _service = DataService();
  Map<String, dynamic>? _billing;
  Map<String, dynamic>? _savings; // ahorro por retos/referidos (Loop #8)
  int _activeDrivers = 1;
  bool _loading = true;
  bool _busy = false;
  bool _yearly = false; // periodo elegido para suscribirse
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final b = await _service.fetchTenantBilling(widget.profile.tenantId);
      int drivers = 1;
      try {
        final list = await _service.listDrivers();
        final n = list.where((d) => d['active'] != false).length;
        drivers = n < 1 ? 1 : n; // mínimo 1 asiento (el propio autónomo)
      } catch (_) {/* best-effort */}
      // Días gratis por retos/referidos: best-effort, no bloquea la pantalla.
      try {
        final s = await _service.tenantFreeDays();
        if (mounted) setState(() => _savings = s);
      } catch (_) {/* sin tarjetas de días gratis */}
      if (!mounted) return;
      setState(() {
        _billing = b;
        _activeDrivers = drivers;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// Formatea un importe en euros sin decimales innecesarios (15,6 / 100).
  String _eur(double v) {
    final s = (v == v.roundToDouble()) ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
    return '${s.replaceAll('.', ',')} €';
  }

  Future<void> _openExternal(String url) async {
    final uri = Uri.parse(url);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.t('sub_no_browser'))));
    }
  }

  Future<void> _subscribe() async {
    setState(() => _busy = true);
    try {
      final url = await _service.createCheckoutSession(seatPriceFor(_yearly));
      await _openExternal(url);
    } catch (e) {
      if (mounted) {
        // Stripe sin configurar -> mensaje claro en vez del error técnico.
        final msg = e.toString().toLowerCase().contains('configurado')
            ? context.l10n.t('sub_unavailable')
            : '${context.l10n.t('error')}: $e';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openPortal() async {
    setState(() => _busy = true);
    try {
      final url = await _service.createPortalSession();
      await _openExternal(url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('${l.t('error')}: $_error'));

    final b = _billing ?? {};
    final status = b['subscription_status'] as String?;
    final hasCustomer = (b['stripe_customer_id'] as String?)?.isNotEmpty == true;
    // Días de prueba restantes (si sigue dentro del periodo de prueba).
    final trialEnds = b['trial_ends_at'] == null
        ? null
        : DateTime.tryParse(b['trial_ends_at'] as String)?.toLocal();
    final trialDaysLeft = (trialEnds != null && DateTime.now().isBefore(trialEnds))
        ? trialEnds.difference(DateTime.now()).inDays + 1
        : 0;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _currentPlanCard(l, status, hasCustomer, trialDaysLeft),
          if (_savings != null) ...[
            const SizedBox(height: 12),
            _savingsCards(l),
          ],
          const SizedBox(height: 24),
          Text(
            subscriptionIsActive(status) ? l.t('sub_change_plan') : l.t('sub_choose_plan'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Center(
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: false, label: Text(l.t('sub_monthly'))),
                ButtonSegment(value: true, label: Text(l.t('sub_yearly'))),
              ],
              selected: {_yearly},
              onSelectionChanged: (s) => setState(() => _yearly = s.first),
            ),
          ),
          const SizedBox(height: 8),
          _seatPlanCard(l, status),
          const SizedBox(height: 12),
          Card(
            color: Colors.amber.shade50,
            child: ListTile(
              leading: const Icon(Icons.card_giftcard, color: Colors.amber),
              title: Text(l.t('set_referral')),
              subtitle: Text(l.t('set_referral_sub')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => ReferralScreen(profile: widget.profile)),
              ),
            ),
          ),
          if (_busy) const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
        ],
      ),
    );
  }

  // --------------- Días gratis por retos/referidos ---------------
  Widget _savingsCards(AppLocalizations l) {
    final s = _savings!;
    final ch = (s['challenges_days'] as num?)?.toInt() ?? 0;
    final rf = (s['referrals_days'] as num?)?.toInt() ?? 0;
    return Row(
      children: [
        _savingsCard(l.t('sav_challenges'), ch,
            const Color(0xFF6A1B9A), Icons.emoji_events, const Key('sav_challenges')),
        const SizedBox(width: 8),
        _savingsCard(l.t('sav_referrals'), rf,
            const Color(0xFF00838F), Icons.group_add, const Key('sav_referrals')),
      ],
    );
  }

  Widget _savingsCard(String label, int days, Color color, IconData icon, Key key) {
    return Expanded(
      child: Card(
        key: key,
        child: InkWell(
          onTap: _openSavingsDetail,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            child: Column(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(height: 6),
                FittedBox(
                  child: Text(context.l10n.t('fd_days', {'n': '$days'}),
                      style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 16)),
                ),
                const SizedBox(height: 2),
                Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Modal con el detalle de las extensiones (días gratis) por retos y referidos.
  Future<void> _openSavingsDetail() async {
    final s = _savings;
    if (s == null) return;
    final l = context.l10n;
    final tCh = (s['challenges_days'] as num?)?.toInt() ?? 0;
    final tRf = (s['referrals_days'] as num?)?.toInt() ?? 0;
    final exts = ((s['challenge_extensions'] as List?) ?? []).cast<Map<String, dynamic>>();
    final miles = ((s['referral_milestones'] as List?) ?? []).cast<Map<String, dynamic>>();
    String fmtDate(String? iso) {
      final d = DateTime.tryParse(iso ?? '')?.toLocal();
      return d == null ? '' : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.t('sav_detail_title'), style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('${l.t('sav_total')}: ${l.t('fd_days', {'n': '${tCh + tRf}'})}',
                  style: Theme.of(ctx).textTheme.bodyMedium),
              Row(children: [
                _dot(const Color(0xFF6A1B9A)),
                Text(' ${l.t('sav_challenges')}: ${l.t('fd_days', {'n': '$tCh'})}   '),
                _dot(const Color(0xFF00838F)),
                Text(' ${l.t('sav_referrals')}: ${l.t('fd_days', {'n': '$tRf'})}'),
              ]),
              const Divider(),
              if (exts.isEmpty && miles.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: Text(l.t('sav_none'), textAlign: TextAlign.center)),
                )
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final e in exts)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.emoji_events, size: 18, color: Color(0xFF6A1B9A)),
                            title: Text(l.t('sav_challenges')),
                            subtitle: Text(fmtDate(e['applied_at'] as String?)),
                            trailing: Text('+${(e['days_extended'] as num?)?.toInt() ?? 0}',
                                style: const TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        for (final m in miles)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.group_add, size: 18, color: Color(0xFF00838F)),
                            title: Text('${l.t('sav_referrals')} · ${l.t('ch_level', {'n': '${m['milestone_level']}'})}'),
                            subtitle: Text(fmtDate(m['created_at'] as String?)),
                            trailing: Text('+${(m['days_awarded'] as num?)?.toInt() ?? 0}',
                                style: const TextStyle(fontWeight: FontWeight.bold)),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dot(Color c) => Container(width: 10, height: 10,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle));

  Widget _currentPlanCard(AppLocalizations l, String? status, bool hasCustomer, int trialDaysLeft) {
    final est = estimatedCost(_activeDrivers, _yearly);
    return Card(
      key: const Key('current_plan_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.workspace_premium, color: Colors.amber),
                const SizedBox(width: 8),
                Text(l.t('sub_seat_plan_name'), style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                Chip(
                  label: Text(l.t(subscriptionStatusKey(status)),
                      style: const TextStyle(color: Colors.white, fontSize: 12)),
                  backgroundColor: subscriptionStatusColor(status),
                ),
              ],
            ),
            if (status == 'trialing' && trialDaysLeft > 0) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(Icons.hourglass_bottom, size: 18, color: Colors.orange),
                  const SizedBox(width: 6),
                  Text(l.t('trial_days_left', {'n': '$trialDaysLeft'}),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Text(l.t('sub_seat_current', {
              'n': '$_activeDrivers',
              'cost': _eur(est),
              'period': _yearly ? l.t('sub_per_year') : l.t('sub_per_month'),
            })),
            if (!subscriptionIsActive(status)) ...[
              const SizedBox(height: 8),
              Text(l.t('sub_inactive_msg'), style: const TextStyle(color: Color(0xFFC62828))),
            ],
            if (hasCustomer) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('open_portal_button'),
                onPressed: _busy ? null : _openPortal,
                icon: const Icon(Icons.receipt_long),
                label: Text(l.t('sub_manage_billing')),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _contactUs() {
    final subject = Uri.encodeComponent('TaxiCount — plan a medida (+$kMaxDrivers conductores)');
    return _openExternal('mailto:$kSupportEmail?subject=$subject');
  }

  // Tarjeta del modelo por asiento (lineal, sin tramo plano): precio por
  // conductor, cupones anuales y estimación para el nº actual de conductores.
  Widget _seatPlanCard(AppLocalizations l, String? status) {
    final over = _activeDrivers > kMaxDrivers;
    final est = estimatedCost(_activeDrivers, _yearly);
    final perDriver = _yearly ? kSeatYearly : kSeatMonthly;
    final period = _yearly ? l.t('sub_per_year') : l.t('sub_per_month');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.t('sub_seat_plan_name'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            _row(Icons.person, l.t('sub_seat_per_driver', {'price': _eur(perDriver), 'period': period})),
            _row(Icons.info_outline, l.t('sub_seat_max', {'max': '$kMaxDrivers'})),
            // Cupones SOLO en el plan anual (el mensual es precio fijo).
            if (_yearly) ...[
              const Divider(height: 20),
              Row(children: [
                const Icon(Icons.local_offer, size: 16, color: Colors.green),
                const SizedBox(width: 6),
                Expanded(child: Text(l.t('sub_coupons_title'),
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green, fontSize: 13))),
              ]),
              const SizedBox(height: 4),
              _row(Icons.card_giftcard, l.t('sub_coupon_welcome', {
                'pct': '$kWelcomeCouponPct',
                'cost': _eur(annualWithCoupon(_activeDrivers, kWelcomeCouponPct)),
              })),
              _row(Icons.loyalty, l.t('sub_coupon_loyalty', {
                'pct': '$kLoyaltyCouponPct',
                'cost': _eur(annualWithCoupon(_activeDrivers, kLoyaltyCouponPct)),
              })),
              const SizedBox(height: 4),
              Text(l.t('sub_coupon_note'), style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
            const Divider(height: 20),
            if (over)
              Text(l.t('sub_over_max', {'n': '$_activeDrivers', 'max': '$kMaxDrivers'}),
                  style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFFC62828)))
            else if (_yearly)
              // Anual: precio de referencia (ancla, en gris) → invita a usar cupón.
              Text('${l.t('sub_anchor')} ${_eur(est)}$period',
                  style: const TextStyle(fontSize: 13, color: Colors.grey,
                      decoration: TextDecoration.lineThrough))
            else
              Text(l.t('sub_seat_estimate',
                  {'n': '$_activeDrivers', 'cost': _eur(est), 'period': period}),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(l.t('sub_seat_note'), style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: over
                  ? OutlinedButton.icon(
                      onPressed: _busy ? null : _contactUs,
                      icon: const Icon(Icons.mail_outline),
                      label: Text(l.t('sub_contact_us')))
                  : FilledButton(
                      key: const Key('subscribe_button'),
                      onPressed: _busy ? null : _subscribe,
                      child: Text(subscriptionIsActive(status) ? l.t('sub_change_plan') : l.t('sub_subscribe')),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(IconData icon, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: Colors.blueGrey),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ]),
      );
}
