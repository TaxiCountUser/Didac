import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'auth_gate.dart';
import 'l10n/app_localizations.dart';
import 'services/data_service.dart';
import 'services/push_service.dart';
import 'screens/admin_screen.dart';
import 'screens/fleet_chat_screen.dart';
import 'screens/fleet_chats_screen.dart';
import 'screens/incidents_screen.dart';
import 'screens/referral_screen.dart';
import 'screens/tickets_screen.dart';
import 'widgets/maintenance_banner.dart';

/// Navegador raíz, para poder navegar desde fuera del árbol (deep-links de push).
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Messenger raíz, para mostrar avisos (SnackBar) desde fuera del árbol, p. ej.
/// una notificación recibida con la app en PRIMER PLANO.
final GlobalKey<ScaffoldMessengerState> rootMessengerKey = GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  // Si algo en build() falla, mostramos un aviso legible en vez de la pantalla
  // roja (o el cierre de la app en release).
  ErrorWidget.builder = (details) => _FatalErrorScreen(details: details);

  // Errores asíncronos no capturados de la plataforma: los registramos pero no
  // dejamos que cierren la app.
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Error no capturado: $error\n$stack');
    return true;
  };

  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('es');
  await localeController.load();
  // ignore: deprecated_member_use
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  // "Recordarme": si el usuario NO marcó recordar sesión, cerramos la sesión
  // persistida al arrancar en frío (así tendrá que volver a entrar).
  try {
    final prefs = await SharedPreferences.getInstance();
    final remember = prefs.getBool('remember_me') ?? true;
    if (!remember && Supabase.instance.client.auth.currentSession != null) {
      await Supabase.instance.client.auth.signOut();
    }
  } catch (_) {/* best-effort */}
  // Cerrar sesión desde una pantalla abierta con push (p. ej. una tarjeta del
  // panel de admin) dejaba el login OCULTO tras esa ruta: el AuthGate se
  // reconstruye en la RAÍZ, pero la tarjeta seguía encima y el login solo
  // aparecía al pulsar "atrás". Al detectar el cierre de sesión, vaciamos la
  // pila de navegación para que el login se vea al instante, venga de donde venga.
  Supabase.instance.client.auth.onAuthStateChange.listen((state) {
    if (state.event == AuthChangeEvent.signedOut) {
      rootNavigatorKey.currentState?.popUntil((r) => r.isFirst);
    }
  });
  // Deep-link: al tocar una notificación, abre el sitio relacionado (no el menú
  // principal). Según el tipo y si el usuario es admin de plataforma o no.
  PushService.onTap = (data) async {
    final type = (data['type'] ?? '').toString();
    final nav = rootNavigatorKey.currentState;
    if (nav == null || type.isEmpty) return;
    try {
      final p = await DataService().fetchMyProfile();
      if (p == null) return;
      Widget? page;
      if (type.startsWith('referral')) {
        page = ReferralScreen(profile: p);
      } else if (p.isAdmin) {
        // Panel de admin: abrir el módulo correspondiente.
        // 0 Soporte · 3 Monitorización · 4 Errores.
        final module = switch (type) {
          'support' => 0,
          'limit' => 3,
          'error_report' => 4,
          _ => null,
        };
        if (module != null) page = AdminModuleScreen(module: module);
      } else if (type == 'fleet') {
        // Chat de flota: el jefe abre el chat de ESE conductor; el conductor
        // abre su chat con el jefe. Títulos localizados (sin context aquí).
        final lang = localeController.value.languageCode;
        final bossTitle = lang == 'en'
            ? 'Message to boss'
            : (lang == 'ca' ? 'Missatge al cap' : 'Mensaje al jefe');
        final msgsTitle =
            lang == 'en' ? 'Messages' : (lang == 'ca' ? 'Missatges' : 'Mensajes');
        if (p.isOwner) {
          final driverId = (data['driverId'] ?? '').toString();
          final name = (data['driverName'] ?? '').toString();
          if (driverId.isNotEmpty) {
            page = FleetChatScreen(
              profile: p,
              driverId: driverId,
              title: name.isEmpty ? msgsTitle : name,
            );
          } else {
            page = FleetChatsScreen(profile: p, standalone: true);
          }
        } else {
          page = FleetChatScreen(profile: p, driverId: p.id, title: bossTitle);
        }
      } else {
        // Usuario normal: soporte -> sus tickets; incidencia -> sus incidencias.
        if (type == 'support') {
          page = TicketsScreen(profile: p);
        } else if (type == 'incident') {
          page = IncidentsScreen(profile: p, standalone: true);
        }
      }
      if (page != null) {
        nav.push(MaterialPageRoute(builder: (_) => page!));
      }
    } catch (_) {/* best-effort */}
  };
  // Notificación recibida con la app en PRIMER PLANO: Android no la muestra sola,
  // así que enseñamos un aviso in-app (SnackBar) con acción para abrirla.
  PushService.onForeground = (data, title, body) {
    final messenger = rootMessengerKey.currentState;
    if (messenger == null) return;
    final text = [title, body].where((s) => (s ?? '').isNotEmpty).join(' · ');
    final lang = localeController.value.languageCode;
    final view = lang == 'en' ? 'View' : (lang == 'ca' ? 'Veure' : 'Ver');
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(text.isEmpty ? 'TaxiCount' : text),
      duration: const Duration(seconds: 6),
      action: SnackBarAction(label: view, onPressed: () => PushService.onTap?.call(data)),
    ));
  };
  // Push (FCM): solo en móvil; en web es no-op. No bloquea el arranque si falla.
  await PushService.instance.init();
  runApp(const TaxiCountApp());
}

/// Pantalla de respaldo cuando el árbol de widgets lanza una excepción.
/// Evita el cierre brusco de la app y deja reintentar.
class _FatalErrorScreen extends StatelessWidget {
  final FlutterErrorDetails details;
  const _FatalErrorScreen({required this.details});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        color: Colors.white,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 16),
            const Text(
              'Algo ha fallado en esta pantalla.\nVuelve atrás e inténtalo de nuevo.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16),
            ),
            if (kDebugMode) ...[
              const SizedBox(height: 16),
              Text('${details.exception}',
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ],
          ],
        ),
      ),
    );
  }
}

class TaxiCountApp extends StatelessWidget {
  const TaxiCountApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Locale>(
      valueListenable: localeController,
      builder: (context, locale, _) => MaterialApp(
        title: 'TaxiCount',
        navigatorKey: rootNavigatorKey,
        scaffoldMessengerKey: rootMessengerKey,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.amber, useMaterial3: true),
        locale: locale,
        supportedLocales: kSupportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        // Respeta el tamaño de letra del sistema, pero acotado (0.85–1.3) para
        // que con letras muy grandes la interfaz no se solape ni se rompa.
        //
        // SafeArea global inferior: con Android 15 (edge-to-edge obligatorio)
        // la app se dibuja DEBAJO de la barra de gestos/botones del sistema y
        // los botones inferiores quedaban tapados en algunos móviles. Un solo
        // SafeArea aquí (envuelve al Navigator) protege TODAS las pantallas;
        // los SafeArea internos no duplican margen (el padding ya consumido
        // llega a 0). El de arriba lo siguen gestionando los AppBar.
        builder: (context, child) {
          final mq = MediaQuery.of(context);
          final clamped = mq.textScaler.clamp(minScaleFactor: 0.85, maxScaleFactor: 1.3);
          return MediaQuery(
            data: mq.copyWith(textScaler: clamped),
            child: SafeArea(
              top: false, left: false, right: false,
              child: Column(
                children: [
                  const MaintenanceBanner(),
                  Expanded(child: child!),
                ],
              ),
            ),
          );
        },
        home: const AuthGate(),
      ),
    );
  }
}
