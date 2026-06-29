import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';

/// Pantalla de referidos "Invita y Gana".
///
/// NOTA (Loop Frontend #2 — Iteración 1): placeholder mínimo para que el
/// proyecto compile tras migrar la capa de datos al backend v2 (por hitos). La
/// UI completa (tarjeta de código, barra de progreso, lista de hitos, historial
/// y compartir con share_plus) se construye en la Iteración 2.
class ReferralScreen extends StatelessWidget {
  final Profile profile;
  const ReferralScreen({super.key, required this.profile});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l.t('set_referral'))),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.card_giftcard, size: 56, color: Colors.amber),
              const SizedBox(height: 12),
              Text(l.t('ref_coming_soon'), textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
