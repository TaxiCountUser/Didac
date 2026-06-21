import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../models/profile.dart';
import '../services/data_service.dart';

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
          .showSnackBar(const SnackBar(content: Text('No se pudo abrir el navegador')));
    }
  }

  Future<void> _choosePlan(PlanInfo plan) async {
    setState(() => _busy = true);
    try {
      final url = await _service.createCheckoutSession(plan.priceId);
      await _openExternal(url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
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
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('Error: $_error'));

    final b = _billing ?? {};
    final status = b['subscription_status'] as String?;
    final planId = b['plan_id'] as String?;
    final limit = b['drivers_limit'];
    final hasCustomer = (b['stripe_customer_id'] as String?)?.isNotEmpty == true;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _currentPlanCard(status, planId, limit, hasCustomer),
          const SizedBox(height: 24),
          Text(
            subscriptionIsActive(status) ? 'Cambiar de plan' : 'Elige un plan',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          ...kPlans.map((p) => _planCard(p, planId)),
          if (_busy) const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
        ],
      ),
    );
  }

  Widget _currentPlanCard(String? status, String? planId, dynamic limit, bool hasCustomer) {
    final limitText = limit == null ? 'Ilimitados' : '$limit';
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
                Text('Plan ${planDisplayName(planId)}',
                    style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                Chip(
                  label: Text(subscriptionStatusLabel(status),
                      style: const TextStyle(color: Colors.white, fontSize: 12)),
                  backgroundColor: subscriptionStatusColor(status),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Conductores incluidos: $limitText'),
            if (!subscriptionIsActive(status)) ...[
              const SizedBox(height: 8),
              const Text(
                'Tu suscripción no está activa. Contrata o reactiva un plan para '
                'seguir registrando transacciones.',
                style: TextStyle(color: Color(0xFFC62828)),
              ),
            ],
            if (hasCustomer) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('open_portal_button'),
                onPressed: _busy ? null : _openPortal,
                icon: const Icon(Icons.receipt_long),
                label: const Text('Gestionar facturación'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _planCard(PlanInfo plan, String? currentPlanId) {
    final isCurrent = plan.id == currentPlanId;
    return Card(
      child: ListTile(
        title: Text(plan.name),
        subtitle: Text(plan.driversText),
        trailing: isCurrent
            ? const Chip(label: Text('Actual'))
            : FilledButton(
                key: Key('choose_plan_${plan.id}'),
                onPressed: _busy ? null : () => _choosePlan(plan),
                child: const Text('Elegir'),
              ),
      ),
    );
  }
}
