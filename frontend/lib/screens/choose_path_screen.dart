import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';

/// Pantalla para un usuario que ha entrado (p. ej. con Google) pero todavía no
/// pertenece a ninguna flota. Puede crear su propia empresa (propietario) o
/// unirse a una flota existente con el código que le da el jefe.
class ChoosePathScreen extends StatefulWidget {
  final VoidCallback onDone;
  const ChoosePathScreen({super.key, required this.onDone});

  @override
  State<ChoosePathScreen> createState() => _ChoosePathScreenState();
}

class _ChoosePathScreenState extends State<ChoosePathScreen> {
  final _service = DataService();
  bool _loading = false;

  Future<void> _createCompany() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.t('cp_create_title')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: ctx.l10n.t('login_company_fleet'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.l10n.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.l10n.t('cp_create_btn'))),
        ],
      ),
    );
    if (ok != true || ctrl.text.trim().isEmpty) return;
    await _run(() => _service.createOwnerCompany(ctrl.text.trim()));
  }

  Future<void> _createSolo() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.t('cp_solo_title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(ctx.l10n.t('cp_solo_help'), style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: InputDecoration(
                labelText: ctx.l10n.t('cp_solo_name'),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.l10n.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.l10n.t('cp_solo_btn'))),
        ],
      ),
    );
    if (ok != true || ctrl.text.trim().isEmpty) return;
    await _run(() => _service.createSoloCompany(ctrl.text.trim()));
  }

  Future<void> _joinFleet() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.t('cp_join_title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(ctx.l10n.t('cp_join_help'), style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: ctx.l10n.t('cp_code'),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.l10n.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.l10n.t('cp_join_btn'))),
        ],
      ),
    );
    if (ok != true || ctrl.text.trim().isEmpty) return;
    await _run(() async {
      final fleet = await _service.joinFleetWithCode(ctrl.text.trim());
      if (mounted && fleet.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.l10n.t('cp_joined', {'name': fleet}))));
      }
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _loading = true);
    try {
      await action();
      widget.onDone(); // recarga el perfil -> AuthGate enruta a la pantalla correcta
    } catch (e) {
      if (mounted) {
        final msg = e.toString().replaceFirst('Exception: ', '');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${context.l10n.t('error')}: $msg')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: const Text('TaxiCount'),
        actions: [
          IconButton(
            tooltip: l.t('logout'),
            onPressed: () => Supabase.instance.client.auth.signOut(),
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
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.groups, size: 64, color: Colors.amber),
                  const SizedBox(height: 12),
                  Text(l.t('cp_title'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Text(l.t('cp_subtitle'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 28),
                  if (_loading) const Center(child: CircularProgressIndicator()) else ...[
                    _PathCard(
                      icon: Icons.business,
                      color: Colors.amber.shade700,
                      label: l.t('cp_create_card'),
                      subtitle: l.t('cp_create_card_sub'),
                      onTap: _createCompany,
                    ),
                    const SizedBox(height: 16),
                    _PathCard(
                      icon: Icons.person_pin_circle,
                      color: Colors.teal.shade600,
                      label: l.t('cp_solo_card'),
                      subtitle: l.t('cp_solo_card_sub'),
                      onTap: _createSolo,
                    ),
                    const SizedBox(height: 16),
                    _PathCard(
                      icon: Icons.key,
                      color: Colors.blueGrey,
                      label: l.t('cp_join_card'),
                      subtitle: l.t('cp_join_card_sub'),
                      onTap: _joinFleet,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PathCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;
  const _PathCard({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
          child: Row(
            children: [
              Icon(icon, size: 40, color: Colors.white),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(height: 4),
                    Text(subtitle, style: const TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white70),
            ],
          ),
        ),
      ),
    );
  }
}
