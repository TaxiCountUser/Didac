/// Estado de la empresa (public.tenants) relevante para el enrutado de la app:
/// modo autónomo, estado de suscripción y prueba gratuita de 15 días.
class TenantState {
  final String id;
  final String name;
  final bool solo; // modo autónomo: dueño = chófer, sin GPS, solo Starter
  final String? subscriptionStatus; // active | trialing | past_due | canceled | inactive
  final String? planId;
  final DateTime? trialEndsAt;

  const TenantState({
    required this.id,
    required this.name,
    this.solo = false,
    this.subscriptionStatus,
    this.planId,
    this.trialEndsAt,
  });

  /// ¿Tiene suscripción de pago al día? (activa o con margen de cortesía)
  bool get hasPaidSubscription =>
      subscriptionStatus == 'active' || subscriptionStatus == 'past_due';

  /// ¿Sigue dentro de la prueba gratuita?
  bool get inTrial => trialEndsAt != null && DateTime.now().isBefore(trialEndsAt!);

  /// ¿Puede usar la app? (suscripción al día o aún en prueba)
  bool get isUsable => hasPaidSubscription || inTrial;

  /// Días que quedan de prueba (0 si ya caducó o no hay fecha).
  int get trialDaysLeft {
    if (trialEndsAt == null) return 0;
    final d = trialEndsAt!.difference(DateTime.now()).inDays;
    return d < 0 ? 0 : d + 1; // +1 para que "hoy" cuente como un día restante
  }

  factory TenantState.fromMap(Map<String, dynamic> m) => TenantState(
        id: m['id'] as String,
        name: (m['name'] as String?) ?? '',
        solo: (m['solo'] as bool?) ?? false,
        subscriptionStatus: m['subscription_status'] as String?,
        planId: m['plan_id'] as String?,
        trialEndsAt: m['trial_ends_at'] == null
            ? null
            : DateTime.tryParse(m['trial_ends_at'] as String)?.toLocal(),
      );
}
