import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/profile.dart';
import 'owner_dashboard_screen.dart';
import 'vehicles_screen.dart';
import 'drivers_screen.dart';
import 'subscription_screen.dart';
import 'incidents_screen.dart';
import 'settings_screen.dart';

/// Home del Owner: pestañas de Vehículos y Conductores.
class OwnerHomeScreen extends StatefulWidget {
  final Profile profile;
  const OwnerHomeScreen({super.key, required this.profile});

  @override
  State<OwnerHomeScreen> createState() => _OwnerHomeScreenState();
}

class _OwnerHomeScreenState extends State<OwnerHomeScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      OwnerDashboardScreen(profile: widget.profile),
      VehiclesScreen(profile: widget.profile),
      DriversScreen(profile: widget.profile),
      IncidentsScreen(profile: widget.profile),
      SubscriptionScreen(profile: widget.profile),
    ];
    const titles = ['Dashboard', 'Vehículos', 'Conductores', 'Incidencias', 'Suscripción'];
    return Scaffold(
      appBar: AppBar(
        title: Text(titles[_index]),
        actions: [
          IconButton(
            key: const Key('settings_button'),
            tooltip: 'Ajustes',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SettingsScreen(profile: widget.profile)),
            ),
            icon: const Icon(Icons.settings),
          ),
          IconButton(
            tooltip: 'Cerrar sesión',
            onPressed: () => Supabase.instance.client.auth.signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.directions_car_outlined),
            selectedIcon: Icon(Icons.directions_car),
            label: 'Vehículos',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'Conductores',
          ),
          NavigationDestination(
            icon: Icon(Icons.report_problem_outlined),
            selectedIcon: Icon(Icons.report_problem),
            label: 'Incidencias',
          ),
          NavigationDestination(
            icon: Icon(Icons.workspace_premium_outlined),
            selectedIcon: Icon(Icons.workspace_premium),
            label: 'Suscripción',
          ),
        ],
      ),
    );
  }
}
