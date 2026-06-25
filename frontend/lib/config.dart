// Configuración de TaxiCount. Sobreescribible con --dart-define.
const supabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'http://localhost:54321',
);

const supabaseAnonKey = String.fromEnvironment(
  'SUPABASE_ANON_KEY',
  defaultValue:
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlLWRlbW8iLCJpYXQiOjE3MDAwMDAwMDAsImV4cCI6MjAwMDAwMDAwMH0.ZxBhVEYye2lqm5NDdkey-JP6uTHcqvZriXUoBtyQniY',
);

// Backend Fastify (creación de conductores con service_role).
const backendUrl = String.fromEnvironment(
  'BACKEND_URL',
  defaultValue: 'http://localhost:3000',
);

// Stripe (Fase 4): Price IDs de los planes. Deben coincidir con los del
// backend (STRIPE_PRICE_*). Por defecto, los placeholders de desarrollo.
const stripePriceStarter = String.fromEnvironment(
  'STRIPE_PRICE_STARTER',
  defaultValue: 'price_starter_placeholder',
);
const stripePricePro = String.fromEnvironment(
  'STRIPE_PRICE_PRO',
  defaultValue: 'price_pro_placeholder',
);
const stripePriceBusiness = String.fromEnvironment(
  'STRIPE_PRICE_BUSINESS',
  defaultValue: 'price_business_placeholder',
);

// Precios anuales (opcionales). Si están vacíos, solo se ofrece el mensual.
const stripePriceStarterYearly = String.fromEnvironment('STRIPE_PRICE_STARTER_YEARLY', defaultValue: '');
const stripePriceProYearly = String.fromEnvironment('STRIPE_PRICE_PRO_YEARLY', defaultValue: '');
const stripePriceBusinessYearly = String.fromEnvironment('STRIPE_PRICE_BUSINESS_YEARLY', defaultValue: '');

/// Catálogo de planes para la UI (nombre, límite y priceId mensual/anual).
/// Los importes son SOLO para mostrar; deben coincidir con los de Stripe.
class PlanInfo {
  final String id;
  final String name;
  final String driversText;
  final String priceId; // mensual
  final String priceIdYearly; // anual (vacío = no disponible)
  final String priceMonthlyText; // p. ej. "1 €/mes"
  final String priceYearlyText; // p. ej. "10 €/año"
  const PlanInfo(
    this.id,
    this.name,
    this.driversText,
    this.priceId, [
    this.priceIdYearly = '',
    this.priceMonthlyText = '',
    this.priceYearlyText = '',
  ]);

  /// Price ID según el periodo elegido (cae al mensual si no hay anual).
  String priceFor(bool yearly) =>
      (yearly && priceIdYearly.isNotEmpty) ? priceIdYearly : priceId;

  /// Importe a mostrar según el periodo.
  String priceText(bool yearly) =>
      (yearly && priceYearlyText.isNotEmpty) ? priceYearlyText : priceMonthlyText;
}

const kPlans = <PlanInfo>[
  PlanInfo('starter', 'Starter', 'Hasta 2 conductores', stripePriceStarter, stripePriceStarterYearly, '1 €/mes', '10 €/año'),
  PlanInfo('pro', 'Pro', 'Hasta 10 conductores', stripePricePro, stripePriceProYearly, '2 €/mes', '20 €/año'),
  PlanInfo('business', 'Business', 'Conductores ilimitados', stripePriceBusiness, stripePriceBusinessYearly, '3 €/mes', '30 €/año'),
];

/// ¿Hay algún plan con precio anual configurado? (para mostrar el selector).
bool get kHasYearlyPlans => kPlans.any((p) => p.priceIdYearly.isNotEmpty);
