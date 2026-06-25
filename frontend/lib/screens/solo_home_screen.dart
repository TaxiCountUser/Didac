import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import 'owner_home_screen.dart';
import 'driver_home_screen.dart';
import 'settings_screen.dart';

/// Modo autónomo: el usuario es su propia empresa y su propio chófer. Un
/// conmutador arriba alterna entre la vista de Empresa (gestión) y la de Chófer
/// (registrar carreras). Sin GPS.
class SoloHomeScreen extends StatefulWidget {
  final Profile profile;
  const SoloHomeScreen({super.key, required this.profile});

  @override
  State<SoloHomeScreen> createState() => _SoloHomeScreenState();
}

class _SoloHomeScreenState extends State<SoloHomeScreen> {
  int _mode = 1; // 0 = Empresa, 1 = Chófer (arranca en lo más usado: registrar)

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        title: SegmentedButton<int>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: 0,
              icon: const Icon(Icons.business, size: 18),
              label: Text(l.t('solo_company')),
            ),
            ButtonSegment(
              value: 1,
              icon: const Icon(Icons.local_taxi, size: 18),
              label: Text(l.t('solo_driver')),
            ),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => setState(() => _mode = s.first),
        ),
        actions: [
          IconButton(
            key: const Key('settings_button'),
            tooltip: l.t('settings'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SettingsScreen(profile: widget.profile)),
            ),
            icon: const Icon(Icons.settings),
          ),
          IconButton(
            tooltip: l.t('logout'),
            onPressed: () => Supabase.instance.client.auth.signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      // IndexedStack mantiene el estado de ambas vistas al alternar.
      body: IndexedStack(
        index: _mode,
        children: [
          OwnerHomeScreen(profile: widget.profile, embedded: true),
          DriverHomeScreen(profile: widget.profile, embedded: true),
        ],
      ),
    );
  }
}
