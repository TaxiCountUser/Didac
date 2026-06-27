import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../services/update_service.dart';

/// Muestra (una vez por arranque) el aviso de actualización si hay versión nueva.
/// - Botón "Actualizar": abre el enlace de descarga del APK nuevo.
/// - X / "Ahora no": cierra. Si la versión es incompatible (mandatory), antes
///   de cerrar avisa de que lo que anote podría no guardarse bien.
bool _shownThisLaunch = false;

Future<void> maybeShowUpdate(BuildContext context) async {
  if (_shownThisLaunch) return;
  final info = await UpdateService.check();
  if (info == null) return;
  _shownThisLaunch = true;
  if (!context.mounted) return;
  await _showDialog(context, info);
}

Future<void> _openApk(BuildContext context, String url) async {
  if (url.isEmpty) return;
  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

Future<void> _showDialog(BuildContext context, UpdateInfo info) async {
  final l = context.l10n;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.system_update, color: Colors.amber),
          const SizedBox(width: 8),
          Expanded(child: Text(l.t('upd_title'))),
          IconButton(
            tooltip: l.t('close'),
            icon: const Icon(Icons.close),
            onPressed: () => _onClose(ctx, info),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.t('upd_body', {'version': info.latestName})),
          if (info.notes.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(info.notes, style: const TextStyle(fontSize: 13, color: Colors.grey)),
          ],
          if (info.mandatory) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.orange.shade50, borderRadius: BorderRadius.circular(8)),
              child: Text(l.t('upd_recommended'),
                  style: const TextStyle(fontSize: 12, color: Colors.deepOrange)),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => _onClose(ctx, info), child: Text(l.t('upd_later'))),
        FilledButton.icon(
          onPressed: () => _openApk(ctx, info.apkUrl),
          icon: const Icon(Icons.download),
          label: Text(l.t('upd_update')),
        ),
      ],
    ),
  );
}

// Al intentar cerrar: si es incompatible, confirma el riesgo antes de salir.
Future<void> _onClose(BuildContext ctx, UpdateInfo info) async {
  final l = ctx.l10n;
  if (!info.mandatory) {
    Navigator.pop(ctx);
    return;
  }
  final stay = await showDialog<bool>(
    context: ctx,
    builder: (c) => AlertDialog(
      title: Text(l.t('upd_warn_title')),
      content: Text(l.t('upd_warn_body')),
      actions: [
        FilledButton.icon(
          onPressed: () { Navigator.pop(c, false); _openApk(ctx, info.apkUrl); },
          icon: const Icon(Icons.download),
          label: Text(l.t('upd_update')),
        ),
        TextButton(onPressed: () => Navigator.pop(c, true), child: Text(l.t('upd_keep_old'))),
      ],
    ),
  );
  if (stay == true && ctx.mounted) Navigator.pop(ctx); // cierra el aviso principal
}
