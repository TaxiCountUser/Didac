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

String planDisplayName(String? planId) {
  final p = kPlans.where((e) => e.id == planId);
  return p.isNotEmpty ? p.first.name : 'Sin plan';
}

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
      if (!mounted) return;
      setState(() {
        _billing = b;
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

  Future<void> _openExternal(String url) async {
    final uri = Uri.parse(url);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.t('sub_no_browser'))));
    }
  }

  Future<void> _choosePlan(PlanInfo plan) async {
    setState(() => _busy = true);
    try {
      final url = await _service.createCheckoutSession(plan.priceFor(_yearly));
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
    final planId = b['plan_id'] as String?;
    final limit = b['drivers_limit'];
    final hasCustomer = (b['stripe_customer_id'] as String?)?.isNotEmpty == true;
    final solo = b['solo'] == true;
    // En modo autónomo solo se ofrece el plan Starter (1 €/mes).
    final plans = solo ? kPlans.where((p) => p.id == 'starter').toList() : kPlans;
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
          if (trialDaysLeft > 0 && !subscriptionIsActive(status)) ...[
            Card(
              color: Colors.amber.shade100,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(Icons.hourglass_bottom, color: Colors.orange),
                    const SizedBox(width: 8),
                    Expanded(child: Text(l.t('trial_days_left', {'n': '$trialDaysLeft'}))),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          _currentPlanCard(l, status, planId, limit, hasCustomer),
          const SizedBox(height: 24),
          Text(
            subscriptionIsActive(status) ? l.t('sub_change_plan') : l.t('sub_choose_plan'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (kHasYearlyPlans && !solo) ...[
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
          ],
          ...plans.map((p) => _planCard(l, p, planId)),
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

  Widget _currentPlanCard(AppLocalizations l, String? status, String? planId, dynamic limit, bool hasCustomer) {
    final limitText = limit == null ? l.t('sub_unlimited') : '$limit';
    final planName = kPlans.where((e) => e.id == planId).isNotEmpty
        ? kPlans.firstWhere((e) => e.id == planId).name
        : l.t('sub_no_plan');
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
                Text('${l.t('sub_plan_prefix')} $planName',
                    style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                Chip(
                  label: Text(l.t(subscriptionStatusKey(status)),
                      style: const TextStyle(color: Colors.white, fontSize: 12)),
                  backgroundColor: subscriptionStatusColor(status),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(l.t('sub_drivers_included', {'n': limitText})),
            if (!subscriptionIsActive(status)) ...[
              const SizedBox(height: 8),
              Text(
                l.t('sub_inactive_msg'),
                style: const TextStyle(color: Color(0xFFC62828)),
              ),
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

  Widget _planCard(AppLocalizations l, PlanInfo plan, String? currentPlanId) {
    final isCurrent = plan.id == currentPlanId;
    final price = plan.priceText(_yearly);
    return Card(
      child: ListTile(
        title: Text(price.isEmpty ? plan.name : '${plan.name} · $price'),
        subtitle: Text(l.t('plan_${plan.id}_desc')),
        trailing: isCurrent
            ? Chip(label: Text(l.t('sub_current')))
            : FilledButton(
                key: Key('choose_plan_${plan.id}'),
                onPressed: _busy ? null : () => _choosePlan(plan),
                child: Text(l.t('sub_choose')),
              ),
      ),
    );
  }
}
