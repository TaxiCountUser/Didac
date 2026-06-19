import 'package:flutter/material.dart';

import '../models/profile.dart';
import '../services/data_service.dart';
import 'vehicles_screen.dart';
import 'drivers_screen.dart';

/// Onboarding del Owner (primera vez): guía para crear el primer
/// vehículo y el primer conductor.
class OnboardingScreen extends StatelessWidget {
  final Profile profile;
  final VoidCallback onFinished;
  const OnboardingScreen({
    super.key,
    required this.profile,
    required this.onFinished,
  });

  @override
  Widget build(BuildContext context) {
    final service = DataService();
    return Scaffold(
      appBar: AppBar(title: const Text('Bienvenido a TaxiCount')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            Text(
              '¡Empecemos! 🚕',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              'Configura tu flota en dos pasos. Puedes hacerlo ahora o más tarde.',
            ),
            const SizedBox(height: 24),
            Card(
              child: ListTile(
                leading: const Icon(Icons.directions_car),
                title: const Text('1. Añade tu primer vehículo'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: const Text('Vehículos')),
                      body: VehiclesScreen(profile: profile),
                    ),
                  ),
                ),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.people),
                title: const Text('2. Invita a tu primer conductor'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: const Text('Conductores')),
                      body: DriversScreen(profile: profile),
                    ),
                  ),
                ),
              ),
            ),
            const Spacer(),
            FilledButton(
              key: const Key('finish_onboarding_btn'),
              onPressed: () async {
                await service.completeOnboarding();
                onFinished();
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Finalizar configuración'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
