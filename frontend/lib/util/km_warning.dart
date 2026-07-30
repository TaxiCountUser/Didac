import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Umbral de salto de km (nuevo − último) a partir del cual avisamos: un salto
/// enorme respecto al último cuentakilómetros conocido puede afectar a los
/// retos / al antifraude.
const kmJumpWarn = 700;

/// Diálogo de confirmación (NO bloquea: es solo un aviso) cuando el salto de km
/// respecto al último registrado supera [kmJumpWarn]. Devuelve true si el
/// usuario decide guardar igual. Se usa al registrar un viaje y al cerrar la
/// jornada.
Future<bool> confirmKmJump(BuildContext context, int km) async {
  final l = context.l10n;
  final res = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.warning_amber_rounded),
      title: Text(l.t('km_jump_title', {'km': km.toString()})),
      content: Text(l.t('km_jump_body')),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(l.t('km_jump_review')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(l.t('km_jump_keep')),
        ),
      ],
    ),
  );
  return res ?? false;
}
