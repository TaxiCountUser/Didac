import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:taxicount/l10n/app_localizations.dart';
import 'package:taxicount/models/profile.dart';
import 'package:taxicount/screens/login_screen.dart';
import 'package:taxicount/screens/driver_home_screen.dart';

/// Envuelve la pantalla con localización (ES) para los tests.
Widget _app(Widget home) => MaterialApp(
      locale: const Locale('es'),
      supportedLocales: kSupportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: home,
    );

void main() {
  testWidgets('Login muestra los campos básicos', (tester) async {
    await tester.pumpWidget(_app(const LoginScreen()));
    await tester.pumpAndSettle();

    expect(find.text('TaxiCount'), findsOneWidget);
    expect(find.byKey(const Key('email_field')), findsOneWidget);
    expect(find.byKey(const Key('password_field')), findsOneWidget);
  });

  testWidgets('Driver: vista limitada sin vehículos ni conductores', (tester) async {
    const profile = Profile(
      id: 'd1',
      tenantId: 't1',
      email: 'driver@test.com',
      name: 'Ana',
      role: 'driver',
    );
    await tester.pumpWidget(_app(const DriverHomeScreen(profile: profile)));
    await tester.pump();

    // Saludo + las dos acciones del conductor (en español).
    expect(find.textContaining('Hola'), findsOneWidget);
    expect(find.text('Añadir registro'), findsOneWidget);
    expect(find.text('Ver transacciones'), findsOneWidget);
    // No deben existir opciones de gestión propias del Owner.
    expect(find.text('Vehículos'), findsNothing);
    expect(find.text('Conductores'), findsNothing);
  });
}
