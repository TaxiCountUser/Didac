import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:taxicount/models/profile.dart';
import 'package:taxicount/screens/login_screen.dart';
import 'package:taxicount/screens/driver_home_screen.dart';

void main() {
  testWidgets('Login muestra los campos básicos', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));

    expect(find.text('TaxiCount'), findsOneWidget);
    expect(find.byKey(const Key('email_field')), findsOneWidget);
    expect(find.byKey(const Key('password_field')), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Entrar'), findsOneWidget);
  });

  testWidgets('Driver: vista limitada sin vehículos ni conductores', (tester) async {
    const profile = Profile(
      id: 'd1',
      tenantId: 't1',
      email: 'driver@test.com',
      name: 'Ana',
      role: 'driver',
    );
    await tester.pumpWidget(const MaterialApp(home: DriverHomeScreen(profile: profile)));

    expect(find.textContaining('Bienvenido'), findsOneWidget);
    // No deben existir opciones de gestión propias del Owner.
    expect(find.text('Vehículos'), findsNothing);
    expect(find.text('Conductores'), findsNothing);
  });
}
