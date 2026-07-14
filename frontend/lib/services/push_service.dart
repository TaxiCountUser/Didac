import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
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

  /// Callback al RECIBIR una notificación con la app en primer plano. Android no
  /// la muestra sola en ese caso; main.dart enseña un aviso in-app (SnackBar).
  static void Function(Map<String, dynamic> data, String? title, String? body)? onForeground;

  /// Inicializa Firebase + messaging. Seguro de llamar varias veces; no lanza.
  Future<void> init() async {
    if (kIsWeb || _inited) return;
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(_bgHandler);
      // Notificación RECIBIDA con la app en primer plano: el sistema no la muestra,
      // así que avisamos in-app (SnackBar) vía el callback de main.dart.
      FirebaseMessaging.onMessage.listen((m) =>
          onForeground?.call(m.data, m.notification?.title, m.notification?.body));
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

  /// Tras iniciar sesión: si las notificaciones YA están activas, solo guarda el
  /// token. Si NO lo están, avisa como mucho UNA vez por versión (es decir, tras
  /// cada actualización, nunca en cada apertura), y solo a quien no las tiene:
  ///   - si el sistema aún puede preguntar -> muestra su diálogo de permiso;
  ///   - si el usuario lo denegó en firme -> aviso in-app que abre los ajustes.
  /// Best-effort; nunca lanza ni bloquea el arranque.
  Future<void> ensureRegistered(BuildContext context, String tenantId) async {
    if (kIsWeb) return;
    try {
      await init();
      // Ya activas: solo asegurar el token guardado, sin molestar.
      if (await notificationsGranted()) {
        await register(tenantId);
        return;
      }
      // No activas: como mucho una vez por VERSIÓN (tras una actualización).
      final prefs = await SharedPreferences.getInstance();
      final info = await PackageInfo.fromPlatform();
      const key = 'notif_prompt_version';
      if (prefs.getString(key) == info.version) return;
      await prefs.setString(key, info.version);

      // Intenta pedir el permiso (muestra el diálogo del sistema si aún puede).
      final status = await register(tenantId);
      if (status == 'granted') return;

      // Si el sistema todavía podría preguntar (no es denegación permanente), su
      // diálogo ya se mostró: no añadimos un aviso in-app encima.
      final permanent = defaultTargetPlatform == TargetPlatform.android &&
          await Permission.notification.isPermanentlyDenied;
      if (!permanent || !context.mounted) return;

      // Denegación permanente: el sistema ya no pregunta -> guiamos a los ajustes.
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
      if (go == true) await openAppSettings();
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
      final session = Supabase.instance.client.auth.currentSession;
      if (session == null) return;
      // Se guarda a través del backend (service_role), NO directo a Supabase: al
      // cambiar de usuario en el mismo dispositivo hay que reasignar el token a
      // quien inicia sesión ahora, y el RLS directo lo impediría (la fila la
      // posee el usuario anterior) fallando en silencio.
      await http.post(
        Uri.parse('$backendUrl/api/v1/device-token'),
        headers: {
          'Authorization': 'Bearer ${session.accessToken}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'token': token,
          'tenant_id': tenantId.isEmpty ? null : tenantId,
          'platform': defaultTargetPlatform.name,
        }),
      );
    } catch (_) {}
  }
}
