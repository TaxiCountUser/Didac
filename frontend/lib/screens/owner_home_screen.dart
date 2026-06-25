import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import '../services/push_service.dart';
import 'owner_dashboard_screen.dart';
import 'vehicles_screen.dart';
import 'drivers_screen.dart';
import 'incidents_screen.dart';
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
  int _openIncidents = 0;

  @override
  void initState() {
    super.initState();
    _loadIncidentCount();
    PushService.instance.register(widget.profile.tenantId);
  }

  Future<void> _loadIncidentCount() async {
    try {
      // Autolimpieza de incidencias antiguas (>90 días), best-effort.
      try { await DataService().cleanupOldIncidents(); } catch (_) {}
      final n = await DataService().openIncidentsCount();
      if (mounted) setState(() => _openIncidents = n);
    } catch (_) {/* badge best-effort */}
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      OwnerDashboardScreen(profile: widget.profile),
      VehiclesScreen(profile: widget.profile),
      DriversScreen(profile: widget.profile),
      IncidentsScreen(profile: widget.profile),
    ];
    final l = context.l10n;
    final titles = [
      l.t('nav_dashboard'), l.t('nav_vehicles'), l.t('nav_drivers'),
      l.t('nav_incidents'),
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
        onDestinationSelected: (i) {
          setState(() => _index = i);
          _loadIncidentCount(); // refresca el badge al navegar
        },
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
            icon: Badge(
              isLabelVisible: _openIncidents > 0,
              label: Text('$_openIncidents'),
              child: const Icon(Icons.report_problem_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: _openIncidents > 0,
              label: Text('$_openIncidents'),
              child: const Icon(Icons.report_problem),
            ),
            label: l.t('nav_incidents'),
          ),
        ],
      ),
    );
  }
}
