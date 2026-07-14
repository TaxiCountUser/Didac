import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/push_service.dart';
import 'owner_dashboard_screen.dart';
import 'vehicles_screen.dart';
import 'drivers_screen.dart';
import 'fleet_chats_screen.dart';
import 'settings_screen.dart';

/// Home del Owner: pestañas de Vehículos y Conductores.
///
/// [embedded] = true cuando se muestra dentro del modo autónomo (SoloHome):
/// se omite la AppBar (el conmutador Empresa/Chófer ya la aporta el contenedor).
class OwnerHomeScreen extends StatefulWidget {
  final Profile profile;
  final bool embedded;
  const OwnerHomeScreen({super.key, required this.profile, this.embedded = false});

  @override
  State<OwnerHomeScreen> createState() => _OwnerHomeScreenState();
}

class _OwnerHomeScreenState extends State<OwnerHomeScreen> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // Notificaciones: registra token y, si no están activas, avisa (1×/versión).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) PushService.instance.ensureRegistered(context, widget.profile.tenantId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      OwnerDashboardScreen(profile: widget.profile),
      VehiclesScreen(profile: widget.profile),
      DriversScreen(profile: widget.profile),
      FleetChatsScreen(profile: widget.profile),
    ];
    final l = context.l10n;
    final titles = [
      l.t('nav_dashboard'), l.t('nav_vehicles'), l.t('nav_drivers'),
      l.t('nav_messages'),
    ];
    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(
              title: Text(titles[_index]),
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
      body: pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.dashboard_outlined),
            selectedIcon: const Icon(Icons.dashboard),
            label: l.t('nav_dashboard'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.directions_car_outlined),
            selectedIcon: const Icon(Icons.directions_car),
            label: l.t('nav_vehicles'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.people_outline),
            selectedIcon: const Icon(Icons.people),
            label: l.t('nav_drivers'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.chat_bubble_outline),
            selectedIcon: const Icon(Icons.chat_bubble),
            label: l.t('nav_messages'),
          ),
        ],
      ),
    );
  }
}
