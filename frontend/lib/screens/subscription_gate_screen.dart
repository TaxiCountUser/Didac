import 'package:flutter/material.dart';

import '../config.dart';
import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import 'subscription_screen.dart';
import '../util/sign_out.dart';

/// Pantalla de bloqueo: la prueba de 15 días terminó y no hay suscripción
/// activa. El Owner/autónomo puede suscribirse; el conductor solo ve el aviso
/// (debe avisar a su jefe).
class SubscriptionGateScreen extends StatelessWidget {
  final Profile profile;
  final VoidCallback onChanged; // recargar tras volver de suscripción
  const SubscriptionGateScreen({super.key, required this.profile, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final canSubscribe = profile.isOwner; // owner y autónomo (role 'owner')
    return Scaffold(
      appBar: AppBar(
        title: Text(l.t('gate_title')),
        actions: [
          IconButton(
            tooltip: l.t('logout'),
            onPressed: () => appSignOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_clock, size: 72, color: Colors.amber),
                  const SizedBox(height: 16),
                  Text(
                    l.t('gate_heading'),
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    !canSubscribe
                        ? l.t('gate_driver_msg')
                        : l.t(kStoreBuild ? 'store_gate_owner_msg' : 'gate_owner_msg'),
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  // Google Play: no se vende en la app; solo "comprobar de nuevo" por si
                  // la suscripción ya se activó fuera.
                  if (canSubscribe && kStoreBuild)
                    FilledButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: Text(l.t('store_recheck')),
                      onPressed: onChanged,
                    ),
                  if (canSubscribe && !kStoreBuild)
                    FilledButton.icon(
                      icon: const Icon(Icons.workspace_premium),
                      label: Text(l.t('gate_subscribe')),
                      onPressed: () async {
                        await Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => Scaffold(
                            appBar: AppBar(title: Text(l.t('nav_subscription'))),
                            body: SubscriptionScreen(profile: profile),
                          ),
                        ));
                        onChanged(); // al volver, reevaluamos el estado
                      },
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
