import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Handler de mensajes en segundo plano (debe ser una función top-level).
@pragma('vm:entry-point')
Future<void> _bgHandler(RemoteMessage message) async {
  // El sistema ya muestra la notificación; no hace falta nada extra.
}

/// Notificaciones push (FCM). Solo en móvil (en web no se inicializa).
/// Todo es best-effort: si Firebase no está disponible, la app funciona igual.
class PushService {
  PushService._();
  static final PushService instance = PushService._();
  bool _inited = false;

  /// Inicializa Firebase + messaging. Seguro de llamar varias veces; no lanza.
  Future<void> init() async {
    if (kIsWeb || _inited) return;
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(_bgHandler);
      _inited = true;
    } catch (_) {/* sin Firebase configurado: la app sigue igual */}
  }

  /// Pide permiso, obtiene el token FCM y lo guarda en device_tokens para el
  /// usuario actual. Llamar tras iniciar sesión (con su tenant).
  Future<void> register(String tenantId) async {
    if (kIsWeb) return;
    try {
      await init();
      if (!_inited) return;
      final fm = FirebaseMessaging.instance;
      await fm.requestPermission();
      final token = await fm.getToken();
      if (token != null) await _save(token, tenantId);
      fm.onTokenRefresh.listen((t) => _save(t, tenantId));
    } catch (_) {}
  }

  Future<void> _save(String token, String tenantId) async {
    try {
      final c = Supabase.instance.client;
      final uid = c.auth.currentUser?.id;
      if (uid == null) return;
      await c.from('device_tokens').upsert({
        'user_id': uid,
        'tenant_id': tenantId.isEmpty ? null : tenantId,
        'token': token,
        'platform': defaultTargetPlatform.name,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'token');
    } catch (_) {}
  }
}
