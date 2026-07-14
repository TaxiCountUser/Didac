import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';

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

  /// Callback al TOCAR una notificación (deep-link). Lo fija main.dart para
  /// navegar según `data['type']` (p. ej. 'referral_milestone' -> Referidos).
  static void Function(Map<String, dynamic> data)? onTap;

  /// Inicializa Firebase + messaging. Seguro de llamar varias veces; no lanza.
  Future<void> init() async {
    if (kIsWeb || _inited) return;
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(_bgHandler);
      // Toque de notificación con la app en segundo plano.
      FirebaseMessaging.onMessageOpenedApp.listen((m) => onTap?.call(m.data));
      // App abierta DESDE una notificación (estado terminado).
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        Future.delayed(const Duration(milliseconds: 800), () => onTap?.call(initial.data));
      }
      _inited = true;
    } catch (_) {/* sin Firebase configurado: la app sigue igual */}
  }

  /// Pide permiso, obtiene el token FCM y lo guarda en device_tokens para el
  /// usuario actual. Llamar tras iniciar sesión (con su tenant).
  ///
  /// Devuelve el estado del permiso ('granted' | 'denied' | 'unsupported' |
  /// 'error') para poder mostrarlo en Ajustes.
  Future<String> register(String tenantId) async {
    if (kIsWeb) return 'unsupported';
    try {
      await init();
      if (!_inited) return 'error';
      final fm = FirebaseMessaging.instance;

      // Android 13+ (POST_NOTIFICATIONS): lo pedimos EXPLÍCITAMENTE con
      // permission_handler, que muestra el diálogo del sistema de forma fiable.
      // (En iOS el permiso lo gestiona firebase_messaging más abajo.)
      var granted = true;
      if (defaultTargetPlatform == TargetPlatform.android) {
        var status = await Permission.notification.status;
        if (!status.isGranted) status = await Permission.notification.request();
        granted = status.isGranted;
      }
      // También el flujo de firebase_messaging (necesario en iOS y para APNs).
      final settings = await fm.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional) {
        granted = true;
      }

      // Aunque el permiso esté denegado, guardamos el token si lo hay (por si se
      // concede luego); sin permiso el sistema no MUESTRA la notificación, pero
      // el envío no falla.
      final token = await fm.getToken();
      if (token != null) await _save(token, tenantId);
      fm.onTokenRefresh.listen((t) => _save(t, tenantId));
      return granted ? 'granted' : 'denied';
    } catch (_) {
      return 'error';
    }
  }

  /// Registra el token y, si las notificaciones NO quedan activas, muestra UNA
  /// vez por versión un aviso para activarlas (para usuarios antiguos que nunca
  /// las concedieron o las denegaron de forma permanente). Best-effort; nunca
  /// lanza ni bloquea el arranque.
  Future<void> ensureRegistered(BuildContext context, String tenantId) async {
    if (kIsWeb) return;
    final status = await register(tenantId); // pide permiso (Android) + guarda token
    if (status == 'granted') return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final info = await PackageInfo.fromPlatform();
      const key = 'notif_prompt_version';
      // Avisamos como mucho UNA vez por versión instalada (no molestar en cada apertura).
      if (prefs.getString(key) == info.version) return;
      await prefs.setString(key, info.version);
      if (!context.mounted) return;
      final l = context.l10n;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l.t('set_notifs')),
          content: Text(l.t('notif_prompt_body')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('later'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('notif_prompt_enable'))),
          ],
        ),
      );
      if (go == true) {
        // Reintenta el permiso; si es denegación permanente, abre los ajustes.
        final again = await register(tenantId);
        if (again != 'granted') await openAppSettings();
      }
    } catch (_) {}
  }

  /// ¿Están concedidas las notificaciones? (para mostrar el estado en Ajustes).
  Future<bool> notificationsGranted() async {
    if (kIsWeb) return false;
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        return (await Permission.notification.status).isGranted;
      }
      final s = await FirebaseMessaging.instance.getNotificationSettings();
      return s.authorizationStatus == AuthorizationStatus.authorized ||
          s.authorizationStatus == AuthorizationStatus.provisional;
    } catch (_) {
      return false;
    }
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
