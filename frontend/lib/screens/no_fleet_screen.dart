import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';

/// Pantalla para un conductor al que el jefe ha sacado de la flota.
/// No puede acceder a ningún dato (la RLS lo bloquea); solo ve este aviso.
class NoFleetScreen extends StatelessWidget {
  const NoFleetScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_accounts, size: 72, color: Colors.grey),
              const SizedBox(height: 16),
              Text(
                l.t('no_fleet_title'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(
                l.t('no_fleet_msg'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => Supabase.instance.client.auth.signOut(),
                icon: const Icon(Icons.logout),
                label: Text(l.t('logout')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
