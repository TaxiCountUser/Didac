import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'admin_auth_gate.dart';
import 'l10n/app_localizations.dart';

/// Entry point de la app WEB de ADMINISTRACIÓN, SEPARADA de la app de operativa
/// (conductores/jefes). Se construye con:
///   flutter build web --target lib/main_admin.dart
/// y se despliega en una URL/repo propios. NO incluye push ni las pantallas de
/// cliente; el APK de operativa (main.dart) NO importa este archivo ni pantallas
/// admin, así que el tree-shaking mantiene ambos mundos separados.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('es');
  await localeController.load();
  // ignore: deprecated_member_use
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  runApp(const TaxiCountAdminApp());
}

class TaxiCountAdminApp extends StatelessWidget {
  const TaxiCountAdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Locale>(
      valueListenable: localeController,
      builder: (context, locale, _) => MaterialApp(
        title: 'TaxiCount · Admin',
        debugShowCheckedModeBanner: false,
        // El kit admin (admin_theme.dart) pinta sus propios colores oscuros por
        // pantalla; aquí solo fijamos un tema base coherente.
        theme: ThemeData(
          colorSchemeSeed: Colors.deepPurple,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        locale: locale,
        supportedLocales: kSupportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        builder: (context, child) {
          final mq = MediaQuery.of(context);
          final clamped = mq.textScaler.clamp(minScaleFactor: 0.85, maxScaleFactor: 1.3);
          return MediaQuery(data: mq.copyWith(textScaler: clamped), child: child!);
        },
        home: const AdminAuthGate(),
      ),
    );
  }
}
