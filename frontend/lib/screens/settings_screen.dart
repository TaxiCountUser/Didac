import 'package:flutter/material.dart';

import '../models/profile.dart';
import '../services/data_service.dart';
import 'incidents_screen.dart';

/// Ajustes: idioma, reportar un fallo de la app e incidencias/mensajes.
class SettingsScreen extends StatelessWidget {
  final Profile profile;
  const SettingsScreen({super.key, required this.profile});

  Future<void> _pickLanguage(BuildContext context) async {
    // De momento solo Español. El multi-idioma (i18n) se añadirá de forma
    // incremental; este selector deja el sitio preparado.
    await showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Idioma'),
        children: [
          ListTile(
            leading: const Icon(Icons.check, color: Colors.green),
            title: const Text('Español'),
            onTap: () => Navigator.pop(ctx),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text('Más idiomas próximamente (English, Català…).',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  Future<void> _reportBug(BuildContext context) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reportar un fallo de la app'),
        content: TextField(
          key: const Key('bug_body'),
          controller: ctrl,
          autofocus: true,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'Describe el problema: qué hacías y qué ha fallado',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Enviar')),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      try {
        await DataService().addIncident(
          tenantId: profile.tenantId,
          kind: 'app',
          body: ctrl.text.trim(),
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('¡Gracias! Incidencia registrada')));
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.language),
            title: const Text('Idioma'),
            subtitle: const Text('Español'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickLanguage(context),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Reportar un fallo de la app'),
            subtitle: const Text('Cuéntanos qué ha ido mal'),
            onTap: () => _reportBug(context),
          ),
          ListTile(
            leading: Icon(profile.isOwner ? Icons.report_problem_outlined : Icons.chat_outlined),
            title: Text(profile.isOwner ? 'Incidencias de la flota' : 'Mensajes al jefe'),
            subtitle: Text(profile.isOwner
                ? 'Mensajes e incidencias de tus conductores'
                : 'Deja una nota o incidencia al jefe'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => IncidentsScreen(profile: profile)),
            ),
          ),
          const Divider(height: 1),
          const AboutListTile(
            icon: Icon(Icons.info_outline),
            applicationName: 'TaxiCount',
            applicationVersion: 'v1.0.0',
            child: Text('Acerca de'),
          ),
        ],
      ),
    );
  }
}
