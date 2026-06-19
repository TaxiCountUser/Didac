import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/profile.dart';
import 'transaction_input_screen.dart';

/// Home del Driver: vista limitada (sin vehículos ni conductores).
class DriverHomeScreen extends StatelessWidget {
  final Profile profile;
  const DriverHomeScreen({super.key, required this.profile});

  @override
  Widget build(BuildContext context) {
    final displayName = profile.name?.isNotEmpty == true ? profile.name! : profile.email;
    return Scaffold(
      appBar: AppBar(
        title: const Text('TaxiCount'),
        actions: [
          IconButton(
            tooltip: 'Cerrar sesión',
            onPressed: () => Supabase.instance.client.auth.signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add_transaction_fab'),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => TransactionInputScreen(profile: profile)),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Registrar'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.local_taxi, size: 64, color: Colors.amber),
              const SizedBox(height: 16),
              Text(
                '¡Bienvenido, $displayName!',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Eres conductor. Pronto podrás registrar tus carreras y gastos aquí.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
