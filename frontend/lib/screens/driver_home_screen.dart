import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/profile.dart';
import 'add_record_screen.dart';
import 'driver_transactions_screen.dart';

/// Home del Driver: elige entre añadir un registro o ver sus transacciones.
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
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.local_taxi, size: 64, color: Colors.amber),
                const SizedBox(height: 12),
                Text(
                  '¡Hola, $displayName!',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                _BigButton(
                  key: const Key('add_record_button'),
                  icon: Icons.add_circle,
                  label: 'Añadir registro',
                  subtitle: 'Carrera o gasto (voz o manual)',
                  color: Colors.amber.shade700,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => AddRecordScreen(profile: profile)),
                  ),
                ),
                const SizedBox(height: 16),
                _BigButton(
                  key: const Key('view_transactions_button'),
                  icon: Icons.receipt_long,
                  label: 'Ver transacciones',
                  subtitle: 'Tu historial de carreras y gastos',
                  color: Colors.blueGrey,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => DriverTransactionsScreen(profile: profile),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;
  const _BigButton({
    super.key,
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
          child: Row(
            children: [
              Icon(icon, size: 40, color: Colors.white),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    const SizedBox(height: 4),
                    Text(subtitle, style: const TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white70),
            ],
          ),
        ),
      ),
    );
  }
}
