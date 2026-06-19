import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'auth_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ignore: deprecated_member_use
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  runApp(const TaxiCountApp());
}

class TaxiCountApp extends StatelessWidget {
  const TaxiCountApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TaxiCount',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.amber, useMaterial3: true),
      home: const AuthGate(),
    );
  }
}
