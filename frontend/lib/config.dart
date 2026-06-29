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
const kSeatMonthly = 2.0; // €/mes por conductor
const kSeatYearly = 15.6; // €/año por conductor (1,3 €/mes)
const kFlatMonthly = 150.0; // €/mes tarifa plana (76+)
const kFlatYearly = 1170.0; // €/año tarifa plana (76+)

/// Price ID del asiento según el periodo elegido.
String seatPriceFor(bool yearly) => yearly ? stripePriceSeatYearly : stripePriceSeatMonthly;

/// Coste estimado para un nº de conductores y periodo (para mostrar en la UI).
double estimatedCost(int drivers, bool yearly) {
  final n = drivers < 1 ? 1 : drivers;
  if (n > kSeatTierLimit) return yearly ? kFlatYearly : kFlatMonthly;
  return n * (yearly ? kSeatYearly : kSeatMonthly);
}
