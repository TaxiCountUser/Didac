import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../changelog.dart';
import '../l10n/app_localizations.dart';

/// "Novedades / Quant a": lista de mejoras por versión, filtradas por rol.
/// El jefe ve las de conductor + las suyas; el conductor solo las de conductor.
/// Las mejoras del panel de administración no aparecen aquí.
class AboutScreen extends StatelessWidget {
  final bool isOwner;
  const AboutScreen({super.key, required this.isOwner});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final lang = localeController.value.languageCode;
    final versions = changelogFor(isOwner: isOwner);
    return Scaffold(
      appBar: AppBar(title: Text(l.t('set_whatsnew'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Versión REAL instalada (de PackageInfo), no un valor fijo.
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snap) {
              final info = snap.data;
              final name = info?.version ?? '—';
              final build = info?.buildNumber ?? '';
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('TaxiCount'),
                  subtitle: Text(build.isEmpty
                      ? 'v$name'
                      : '${l.t('whatsnew_current')}: v$name (build $build)'),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          if (versions.isEmpty)
            Padding(padding: const EdgeInsets.all(24),
                child: Center(child: Text(l.t('whatsnew_empty'))))
          else
            for (final v in versions) ...[
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text('v${v.version}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    ),
                    const SizedBox(width: 10),
                    Text(v.date, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ]),
                  const SizedBox(height: 8),
                  for (final item in v.items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8, left: 2),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 2, right: 8),
                          child: Icon(Icons.check_circle, size: 16, color: Colors.green),
                        ),
                        Expanded(child: Text(item.text(lang), style: const TextStyle(fontSize: 14))),
                      ]),
                    ),
                  const SizedBox(height: 16),
                  const Divider(height: 1),
                  const SizedBox(height: 16),
                ],
                Center(
                  child: Text('TaxiCount',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                ),
              ],
            ),
    );
  }
}
