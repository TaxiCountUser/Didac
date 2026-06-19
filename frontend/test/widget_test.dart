import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:taxicount/main.dart';

void main() {
  testWidgets('La pantalla de login muestra los campos básicos', (tester) async {
    // Renderiza solo la pantalla de login (sin inicializar Supabase).
    await tester.pumpWidget(
      const MaterialApp(home: LoginScreen()),
    );

    expect(find.text('TaxiCount'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Contraseña'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Entrar'), findsOneWidget);
  });
}
