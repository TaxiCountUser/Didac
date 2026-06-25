// Notificaciones push (Firebase Cloud Messaging).
//
// Se activa SOLO si FCM_SERVICE_ACCOUNT está configurado (el JSON de la cuenta
// de servicio de Firebase, como una sola línea). Sin esa variable, todas las
// funciones son no-op: la app sigue funcionando igual, solo que sin push.
//
// El JSON de la cuenta de servicio se obtiene en:
//   Firebase Console -> Configuración del proyecto -> Cuentas de servicio
//   -> "Generar nueva clave privada".

import { readFileSync } from 'node:fs';

let _appPromise = null;

// La cuenta de servicio puede venir como:
//   1) FCM_SERVICE_ACCOUNT  -> el JSON pegado como variable de entorno.
//   2) Secret File de Render (u otra ruta): FCM_SERVICE_ACCOUNT_FILE o, por
//      defecto, /etc/secrets/fcm.json.
function serviceAccount() {
  const raw = (process.env.FCM_SERVICE_ACCOUNT || '').trim();
  if (raw) {
    try {
      return JSON.parse(raw);
    } catch {/* probamos con el archivo */}
  }
  const path = (process.env.FCM_SERVICE_ACCOUNT_FILE || '/etc/secrets/fcm.json').trim();
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    return null;
  }
}

export function pushEnabled() {
  return serviceAccount() != null;
}

// Inicializa firebase-admin una sola vez (import dinámico para no exigir el
// paquete cuando no se usa push).
async function getMessaging() {
  const sa = serviceAccount();
  if (!sa) return null;
  if (!_appPromise) {
    _appPromise = (async () => {
      const admin = (await import('firebase-admin')).default;
      const app = admin.apps.length
        ? admin.app()
        : admin.initializeApp({ credential: admin.credential.cert(sa) });
      return admin.messaging(app);
    })();
  }
  return _appPromise;
}

/**
 * Envía una notificación a un conjunto de tokens FCM.
 * Devuelve { sent, failed, invalidTokens } (invalidTokens hay que borrarlos).
 * Nunca lanza: ante cualquier fallo, registra y devuelve 0 enviados.
 */
export async function sendToTokens(tokens, { title, body, data } = {}, log) {
  const list = [...new Set((tokens || []).filter(Boolean))];
  if (list.length === 0) return { sent: 0, failed: 0, invalidTokens: [] };
  let messaging;
  try {
    messaging = await getMessaging();
  } catch (e) {
    log?.warn?.(`[push] no se pudo inicializar FCM: ${e.message}`);
    return { sent: 0, failed: 0, invalidTokens: [] };
  }
  if (!messaging) return { sent: 0, failed: 0, invalidTokens: [] };

  const message = {
    notification: { title: title || 'TaxiCount', body: body || '' },
    data: Object.fromEntries(
      Object.entries(data || {}).map(([k, v]) => [k, String(v)]),
    ),
    tokens: list,
  };

  try {
    const res = await messaging.sendEachForMulticast(message);
    const invalidTokens = [];
    res.responses.forEach((r, i) => {
      const code = r.error?.code || '';
      if (/registration-token-not-registered|invalid-argument/i.test(code)) {
        invalidTokens.push(list[i]);
      }
    });
    return { sent: res.successCount, failed: res.failureCount, invalidTokens };
  } catch (e) {
    log?.error?.(`[push] envío FCM falló: ${e.message}`);
    return { sent: 0, failed: 0, invalidTokens: [] };
  }
}
