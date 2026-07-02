// Versión vigente de los términos legales / política de privacidad. Súbela
// cuando cambien: todos los usuarios tendrán que volver a aceptarlos al abrir
// la app (control en users.legal_accepted_version).
const kLegalVersion = 1;

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

// Client ID WEB de Google (OAuth). Si se define, en Android se usa el login
// NATIVO (google_sign_in), que muestra "TaxiCount" sin la URL de Supabase. Si
// se deja vacío, se mantiene el login por navegador (signInWithOAuth). Es el
// mismo Client ID que Supabase tiene configurado en su proveedor de Google.
const kGoogleWebClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID', defaultValue: '');

// Manifiesto de versión para el aviso de actualización (sideload). Apunta al
// version.json publicado en la última GitHub Release.
const updateManifestUrl = String.fromEnvironment(
  'UPDATE_URL',
  defaultValue: 'https://github.com/TaxiCountUser/Didac/releases/latest/download/version.json',
);

// Stripe (Fase 4): modelo de precios POR ASIENTO (por conductor), escalonado por
// volumen en Stripe. Un único Price mensual y otro anual; la cantidad = nº de
// conductores. Deben coincidir con los del backend (STRIPE_PRICE_SEAT_*).
const stripePriceSeatMonthly = String.fromEnvironment(
  'STRIPE_PRICE_SEAT_MONTHLY',
  defaultValue: 'price_seat_monthly_placeholder',
);
const stripePriceSeatYearly = String.fromEnvironment(
  'STRIPE_PRICE_SEAT_YEARLY',
  defaultValue: 'price_seat_yearly_placeholder',
);

// Parámetros del modelo de precios (SOLO para mostrar/estimar en la UI; la
// facturación real la calcula Stripe con los tramos por volumen del Price).
const kSeatTierLimit = 75; // 1–75 por asiento; 76–100 tarifa plana
const kMaxDrivers = 100; // tope del modelo; a partir de aquí, plan a medida
const kSeatMonthly = 2.5; // €/mes por conductor
const kSeatYearly = 24.0; // €/año por conductor (2 €/mes efectivo)
const kFlatMonthly = 150.0; // €/mes tarifa plana (76+)
const kFlatYearly = 1170.0; // €/año tarifa plana (76+)

/// Price ID del asiento según el periodo elegido.
String seatPriceFor(bool yearly) => yearly ? stripePriceSeatYearly : stripePriceSeatMonthly;

/// Coste estimado (precio BASE, sin oferta) para un nº de conductores y periodo.
double estimatedCost(int drivers, bool yearly) {
  final n = drivers < 1 ? 1 : drivers;
  if (n > kSeatTierLimit) return yearly ? kFlatYearly : kFlatMonthly;
  return n * (yearly ? kSeatYearly : kSeatMonthly);
}

// Oferta de lanzamiento: cupón PERMANENTE en Stripe (p. ej. TAXI2026) que aplica
// este % de descuento. Aquí SOLO para mostrar el precio con oferta; el descuento
// real lo aplica Stripe con el cupón. 24 €/año -38% ≈ 14,88 €/año.
const kLaunchDiscountPct = 38;

/// Precio con la oferta de lanzamiento aplicada (para mostrar en la UI).
double launchOfferCost(int drivers, bool yearly) =>
    estimatedCost(drivers, yearly) * (100 - kLaunchDiscountPct) / 100;
