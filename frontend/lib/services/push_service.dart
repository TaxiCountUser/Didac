import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../l10n/app_localizations.dart';
import 'data_service.dart';

/// Handler de mensajes en segundo plano (debe ser una función top-level).
@pragma('vm:entry-point')
Future<void> _bgHandler(RemoteMessage message) async {
  // El sistema ya muestra la notificación; no hace falta nada extra.
}

/// Notificaciones push (FCM). En el móvil (Android) y, desde 2026-10-14, también
/// en la WEB del cliente (sobre todo para iPhone: la web añadida a la pantalla de
/// inicio recibe avisos desde iOS 16.4). En la web solo si [webEnabled] (lo pone
/// main.dart; el panel admin no) y si la config web está puesta (config.dart).
/// Todo es best-effort: si Firebase no está disponible, la app funciona igual.
class PushService {
  PushService._();
  static final PushService instance = PushService._();
  static bool webEnabled = false;
  /// ¿Hay avisos en ESTA plataforma? (móvil sí; web solo si está activada).
  static bool get supported => !kIsWeb || (webEnabled && kWebPushConfigured);
  // Web: sin token VAPID no hay avisos; en el móvil no se pasa.
  static String? get _vapid => kIsWeb ? kFirebaseVapidKey : null;
  bool _inited = false;
  // Una sola inicialización aunque la pidan varias pantallas a la vez (el
  // autónomo monta Empresa y Chófer juntas): sin esto se duplicaban los
  // listeners (avisos dobles con la app abierta) y competían entre sí.
  Future<void>? _initFuture;
  bool _refreshHooked = false;
  String? _syncedUserId; // a qué cuenta se apuntó el móvil en esta sesión de app
  bool _reported = false;

  /// Si el móvil NO consigue apuntarse (p. ej. Firebase rechaza la firma de la app,
  /// como pasó al pasar a Google Play), se avisa al admin (Errores técnicos) UNA
  /// vez por arranque, en vez de fallar en silencio.
  void _reportFailure(String what) {
    if (_reported) return;
    _reported = true;
    DataService().reportClientError('push: $what', screen: 'Push').catchError((_) {});
  }

  /// Callback al TOCAR una notificación (deep-link). Lo fija main.dart para
  /// navegar según `data['type']` (p. ej. 'referral_milestone' -> Referidos).
  static void Function(Map<String, dynamic> data)? onTap;

  /// Callback al RECIBIR una notificación con la app en primer plano. Android no
  /// la muestra sola en ese caso; main.dart enseña un aviso in-app (SnackBar).
  static void Function(Map<String, dynamic> data, String? title, String? body)? onForeground;

  /// Inicializa Firebase + messaging. Seguro de llamar varias veces; no lanza.
  Future<void> init() {
    if (!supported || _inited) return Future.value();
    return _initFuture ??= _doInit().whenComplete(() {
      if (!_inited) _initFuture = null; // falló: se podrá reintentar
    });
  }

  Future<void> _doInit() async {
    try {
      if (kIsWeb) {
        // Web: config PÚBLICA de la app web de Firebase (config.dart). Los avisos
        // con la web cerrada los muestra web/firebase-messaging-sw.js.
        await Firebase.initializeApp(options: const FirebaseOptions(
          apiKey: kFirebaseWebApiKey, appId: kFirebaseWebAppId,
          messagingSenderId: kFirebaseSenderId, projectId: kFirebaseProjectId,
        ));
      } else {
        await Firebase.initializeApp();
        FirebaseMessaging.onBackgroundMessage(_bgHandler);
      }
      // Notificación RECIBIDA con la app en primer plano: el sistema no la muestra,
      // así que avisamos in-app (SnackBar) vía el callback de main.dart.
      // Además mostramos la notificación del SISTEMA (con el claxon), para que suene
      // también con la app abierta.
      FirebaseMessaging.onMessage.listen((m) {
        _showSystem(m.notification?.title, m.notification?.body);
        onForeground?.call(m.data, m.notification?.title, m.notification?.body);
      });
      // Toque de notificación con la app en segundo plano.
      FirebaseMessaging.onMessageOpenedApp.listen((m) => onTap?.call(m.data));
      // App abierta DESDE una notificación (estado terminado).
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        Future.delayed(const Duration(milliseconds: 800), () => onTap?.call(initial.data));
      }
      _inited = true;
    } catch (e) {
      _reportFailure('init: $e'); // sin Firebase: la app sigue igual
    }
  }

  /// Pide permiso, obtiene el token FCM y lo guarda en device_tokens para el
  /// usuario actual. Llamar tras iniciar sesión (con su tenant).
  ///
  /// Devuelve el estado del permiso ('granted' | 'denied' | 'unsupported' |
  /// 'error') para poder mostrarlo en Ajustes.
  Future<String> register(String tenantId) async {
    if (!supported) return 'unsupported';
    try {
      await init();
      if (!_inited) return 'error';
      final fm = FirebaseMessaging.instance;

      // Android 13+ (POST_NOTIFICATIONS): lo pedimos EXPLÍCITAMENTE con
      // permission_handler, que muestra el diálogo del sistema de forma fiable.
      // (En iOS el permiso lo gestiona firebase_messaging más abajo.)
      var granted = !kIsWeb;
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
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
      await syncToken(tenantId);
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
    if (!supported) return;
    // Web: NUNCA se pide el permiso solo (iPhone exige que lo pida un botón:
    // Ajustes -> campana). Si ya lo dio, se apunta y listo.
    if (kIsWeb) {
      if (await notificationsGranted()) await syncToken(tenantId);
      return;
    }
    try {
      await init();
      // SIEMPRE: el móvil queda apuntado a la cuenta que está abierta AHORA, tenga
      // o no el permiso concedido (antes, sin permiso no se reasignaba y al cambiar
      // de cuenta el móvil seguía con la anterior: los avisos iban a otra cuenta).
      await syncToken(tenantId);
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

  /// Canal nativo (MainActivity.kt): muestra una notificación del sistema con el
  /// sonido del claxon. Solo Android; nunca lanza.
  static const _native = MethodChannel('taxicount/notify');
  static Future<void> _showSystem(String? title, String? body) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _native.invokeMethod('show', {'title': title ?? 'TaxiCount', 'body': body ?? ''});
    } catch (_) {}
  }

  /// Apunta este móvil a la cuenta abierta (sin pedir permiso). Best-effort.
  /// Devuelve true si quedó apuntado.
  Future<bool> syncToken(String tenantId) async {
    if (!supported) return false;
    try {
      await init();
      if (!_inited) return false;
      // Web: pedir el token sin permiso dispararía el diálogo (y en iPhone falla).
      if (kIsWeb && !await notificationsGranted()) return false;
      final fm = FirebaseMessaging.instance;
      if (!_refreshHooked) {
        _refreshHooked = true;
        fm.onTokenRefresh.listen((t) => _save(t, tenantId));
      }
      final token = await fm.getToken(vapidKey: _vapid);
      if (token == null) {
        _reportFailure('getToken devolvió null');
        return false;
      }
      final ok = await _save(token, tenantId);
      if (ok) _syncedUserId = Supabase.instance.client.auth.currentUser?.id;
      return ok;
    } catch (e) {
      _reportFailure('getToken: $e'); // p. ej. huella de la app no autorizada en Firebase
      return false;
    }
  }

  /// Al ENTRAR en una cuenta (auth_gate, antes de cualquier pantalla): apunta el
  /// móvil a esa cuenta una vez por cuenta y arranque de la app. Así los avisos
  /// van siempre a la cuenta abierta, pase por las pantallas que pase.
  Future<void> syncForUser(String userId, String tenantId) async {
    if (!supported || _syncedUserId == userId) return;
    await syncToken(tenantId);
  }

  /// «Probar aviso» (Ajustes): re-apunta el móvil y pide al servidor una push de
  /// prueba. Devuelve cuántos móviles hay apuntados a esta cuenta (0 = ninguno),
  /// o null si no se pudo contactar con el servidor.
  Future<int?> sendTest(String tenantId) async {
    await syncToken(tenantId);
    try {
      final session = Supabase.instance.client.auth.currentSession;
      if (session == null) return null;
      final res = await http.post(
        Uri.parse('$backendUrl/api/v1/push/test'),
        headers: {'Authorization': 'Bearer ${session.accessToken}'},
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      return ((jsonDecode(res.body) as Map)['devices'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return null;
    }
  }

  /// Al CERRAR SESIÓN: desapunta este móvil de la cuenta que sale, para que deje
  /// de recibir sus avisos aquí. Llamar ANTES de signOut (necesita la sesión).
  /// Con tiempo límite: nunca bloquea el cierre de sesión.
  Future<void> unlinkCurrentUser() async {
    if (!supported || !_inited) return;
    _syncedUserId = null; // la próxima cuenta que entre se volverá a apuntar
    try {
      final session = Supabase.instance.client.auth.currentSession;
      if (session == null) return;
      final token = await FirebaseMessaging.instance.getToken(vapidKey: _vapid)
          .timeout(const Duration(seconds: 3));
      if (token == null) return;
      await http.post(
        Uri.parse('$backendUrl/api/v1/device-token/unlink'),
        headers: {
          'Authorization': 'Bearer ${session.accessToken}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'token': token}),
      ).timeout(const Duration(seconds: 4));
    } catch (_) {}
  }

  /// ¿Están concedidas las notificaciones? (para mostrar el estado en Ajustes).
  Future<bool> notificationsGranted() async {
    if (!supported) return false;
    try {
      if (kIsWeb) await init();
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        return (await Permission.notification.status).isGranted;
      }
      final s = await FirebaseMessaging.instance.getNotificationSettings();
      return s.authorizationStatus == AuthorizationStatus.authorized ||
          s.authorizationStatus == AuthorizationStatus.provisional;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _save(String token, String tenantId) async {
    try {
      final session = Supabase.instance.client.auth.currentSession;
      if (session == null) return false;
      final info = await PackageInfo.fromPlatform();
      // Se guarda a través del backend (service_role), NO directo a Supabase: al
      // cambiar de usuario en el mismo dispositivo hay que reasignar el token a
      // quien inicia sesión ahora, y el RLS directo lo impediría (la fila la
      // posee el usuario anterior) fallando en silencio.
      final res = await http.post(
        Uri.parse('$backendUrl/api/v1/device-token'),
        headers: {
          'Authorization': 'Bearer ${session.accessToken}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'token': token,
          'tenant_id': tenantId.isEmpty ? null : tenantId,
          'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
          'locale': localeController.value.languageCode,
          'app_version': '${info.version}+${info.buildNumber}',
        }),
      ).timeout(const Duration(seconds: 15));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
