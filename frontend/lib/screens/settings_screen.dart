import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import 'incidents_screen.dart';

/// Ajustes: idioma, reportar un fallo de la app e incidencias/mensajes.
class SettingsScreen extends StatelessWidget {
  final Profile profile;
  const SettingsScreen({super.key, required this.profile});

  Future<void> _pickLanguage(BuildContext context) async {
    final current = localeController.value.languageCode;
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(ctx.l10n.t('set_language')),
        children: [
          for (final entry in kLanguageNames.entries)
            ListTile(
              leading: Icon(entry.key == current ? Icons.check : Icons.language,
                  color: entry.key == current ? Colors.green : null),
              title: Text(entry.value),
              onTap: () => Navigator.pop(ctx, entry.key),
            ),
        ],
      ),
    );
    if (code != null) await localeController.setLocale(code);
  }

  Future<void> _reportBug(BuildContext context) async {
    final l = context.l10n;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('bug_title')),
        content: TextField(
          key: const Key('bug_body'),
          controller: ctrl,
          autofocus: true,
          maxLines: 4,
          decoration: InputDecoration(hintText: l.t('bug_hint'), border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('send'))),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      try {
        await DataService().addIncident(
          tenantId: profile.tenantId, kind: 'app', body: ctrl.text.trim());
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('bug_thanks'))));
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l.t('error')}: $e')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l.t('set_title'))),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(l.t('set_language')),
            subtitle: Text(kLanguageNames[localeController.value.languageCode] ?? 'Español'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickLanguage(context),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: Text(l.t('set_report_bug')),
            subtitle: Text(l.t('set_report_bug_sub')),
            onTap: () => _reportBug(context),
          ),
          ListTile(
            leading: Icon(profile.isOwner ? Icons.report_problem_outlined : Icons.chat_outlined),
            title: Text(profile.isOwner ? l.t('set_incidents_owner') : l.t('set_incidents_driver')),
            subtitle: Text(profile.isOwner ? l.t('set_incidents_owner_sub') : l.t('set_incidents_driver_sub')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => IncidentsScreen(profile: profile)),
            ),
          ),
          const Divider(height: 1),
          AboutListTile(
            icon: const Icon(Icons.info_outline),
            applicationName: 'TaxiCount',
            applicationVersion: 'v1.0.0',
            child: Text(l.t('set_about')),
          ),
        ],
      ),
    );
  }
}
