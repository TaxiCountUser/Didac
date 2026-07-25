import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';

/// Muestra un error AMABLE (snackbar localizado, no el texto técnico) y reporta
/// el error real a telemetría (fire-and-forget) para verlo agregado en Auditoría.
/// Uso: en los `catch (e)` imperativos → `showError(context, e, screen: 'X')`.
void showError(BuildContext context, Object error, {String? screen}) {
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.t('err_generic'))),
    );
  }
  // No bloquea; el backend hace throttle por usuario+mensaje.
  DataService().reportClientError(error.toString(), screen: screen);
}

/// Vista de error para `FutureBuilder` (carga fallida): icono + mensaje amable +
/// botón reintentar. NO reporta desde aquí (se construye en build; reportar
/// llevaría a spam). Los errores de acción se reportan con [showError].
Widget errorRetry(BuildContext context, VoidCallback onRetry) {
  final l = context.l10n;
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, size: 40, color: Colors.grey),
          const SizedBox(height: 12),
          Text(l.t('err_load_failed'), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: Text(l.t('err_retry')),
          ),
        ],
      ),
    ),
  );
}
