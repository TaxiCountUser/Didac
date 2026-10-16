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

// Build para Google Play (lo activa build-apk.yml con --dart-define=STORE_BUILD=true).
// Política de Pagos de Play: la app NO vende nada ni dice dónde pagar (sin botón de
// suscribirse, precios, cupones ni portal de Stripe), como Netflix: solo se USA una
// cuenta que se paga fuera. La web (sin el define) sigue con Stripe como siempre.
const kStoreBuild = bool.fromEnvironment('STORE_BUILD');

// (Auto-actualización eliminada: en Google Play las actualizaciones las gestiona
// Play. Antes había un `updateManifestUrl` que apuntaba a la GitHub Release.)

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
// facturación real la calcula Stripe). Modelo POR ASIENTO (por conductor), lineal,
// SIN tramo plano. Máximo 100 conductores; a partir de ahí, plan a medida.
const kMaxDrivers = 100; // tope del modelo; a partir de aquí, contactar
const kSeatMonthly = 3.0; // €/mes por conductor (precio FIJO, sin cupones)
const kSeatYearly = 30.0; // €/año por conductor (anual < 12× mensual → promueve anual)

// Cupones ANUALES (configurados en Stripe; el cliente los introduce en el
// checkout). El mensual nunca lleva cupón.
const kWelcomeCouponPct = 50; // bienvenida: 1 vez por cliente (p. ej. 1er año)
const kLoyaltyCouponPct = 20; // fidelidad: siempre, sin límite de uso

// Contacto para planes a medida (> kMaxDrivers conductores).
const kSupportEmail = String.fromEnvironment(
  'SUPPORT_EMAIL',
  defaultValue: 'soporte@taxicount.com',
);

/// Price ID del asiento según el periodo elegido.
String seatPriceFor(bool yearly) => yearly ? stripePriceSeatYearly : stripePriceSeatMonthly;

/// Coste estimado (precio BASE, sin cupón) para un nº de conductores y periodo.
double estimatedCost(int drivers, bool yearly) {
  final n = drivers < 1 ? 1 : drivers;
  return n * (yearly ? kSeatYearly : kSeatMonthly);
}

/// Precio anual con un cupón (%) aplicado, para mostrar cuánto pagaría el cliente.
double annualWithCoupon(int drivers, int couponPct) =>
    estimatedCost(drivers, true) * (100 - couponPct) / 100;

// ---------------- Avisos en la WEB (iPhone: web en la pantalla de inicio) ----
// Config PÚBLICA de la app web de Firebase «TaxiCount Web» (proyecto
// taxicount-75bc2; no es secreta: va dentro de la web). Se repite en
// web/firebase-messaging-sw.js. Si falta la clave o el VAPID, la web sigue sin avisos.
const kFirebaseWebApiKey = String.fromEnvironment('FIREBASE_WEB_API_KEY',
    defaultValue: 'AIzaSyAz9m9puwF450EtVEAulTF4oc3ND4pwK_A');
const kFirebaseWebAppId = '1:1063875764382:web:9c55d4eb5de28133bf1b8f';
const kFirebaseSenderId = '1063875764382';
const kFirebaseProjectId = 'taxicount-75bc2';
// Clave pública de «Certificados push web» (Firebase → Cloud Messaging).
const kFirebaseVapidKey = String.fromEnvironment('FIREBASE_VAPID_KEY',
    defaultValue: 'BITGV5ZdREXnyfo5Qh8jdozi5NLrbZdyfPQAaU-_5egSBa_b1QLlac5pg9rBB6O-JXjGodhjTCAjxjByfPIkwSw');
const kWebPushConfigured = kFirebaseWebApiKey != '' && kFirebaseVapidKey != '';
