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
import 'screens/referral_screen.dart';
import 'widgets/maintenance_banner.dart';

/// Navegador raíz, para poder navegar desde fuera del árbol (deep-links de push).
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

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
  // Deep-link: al tocar una notificación de referidos, abre la pantalla.
  PushService.onTap = (data) async {
    final type = (data['type'] ?? '').toString();
    if (!type.startsWith('referral')) return;
    try {
      final p = await DataService().fetchMyProfile();
      if (p == null) return;
      rootNavigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => ReferralScreen(profile: p)),
      );
    } catch (_) {/* best-effort */}
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
