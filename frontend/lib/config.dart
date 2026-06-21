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

/// Catálogo de planes para la UI (nombre, límite y priceId).
class PlanInfo {
  final String id;
  final String name;
  final String driversText;
  final String priceId;
  const PlanInfo(this.id, this.name, this.driversText, this.priceId);
}

const kPlans = <PlanInfo>[
  PlanInfo('starter', 'Starter', 'Hasta 2 conductores', stripePriceStarter),
  PlanInfo('pro', 'Pro', 'Hasta 10 conductores', stripePricePro),
  PlanInfo('business', 'Business', 'Conductores ilimitados', stripePriceBusiness),
];
