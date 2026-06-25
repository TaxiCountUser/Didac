import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'auth_gate.dart';
import 'l10n/app_localizations.dart';
import 'services/push_service.dart';

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
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.amber, useMaterial3: true),
        locale: locale,
        supportedLocales: kSupportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: const AuthGate(),
      ),
    );
  }
}
