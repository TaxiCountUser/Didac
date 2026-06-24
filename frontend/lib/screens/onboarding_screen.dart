import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
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
    final l = context.l10n;
    final service = DataService();
    return Scaffold(
      appBar: AppBar(title: Text(l.t('ob_title'))),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            Text(
              l.t('ob_lets_start'),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(l.t('ob_intro')),
            const SizedBox(height: 24),
            Card(
              child: ListTile(
                leading: const Icon(Icons.directions_car),
                title: Text(l.t('ob_step1')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: Text(l.t('nav_vehicles'))),
                      body: VehiclesScreen(profile: profile),
                    ),
                  ),
                ),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.people),
                title: Text(l.t('ob_step2')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: Text(l.t('nav_drivers'))),
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
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(l.t('ob_finish')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
