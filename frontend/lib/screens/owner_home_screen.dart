import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
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
    final l = context.l10n;
    final titles = [
      l.t('nav_dashboard'), l.t('nav_vehicles'), l.t('nav_drivers'),
      l.t('nav_incidents'), l.t('nav_subscription'),
    ];
    return Scaffold(
      appBar: AppBar(
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
            icon: const Icon(Icons.report_problem_outlined),
            selectedIcon: const Icon(Icons.report_problem),
            label: l.t('nav_incidents'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.workspace_premium_outlined),
            selectedIcon: const Icon(Icons.workspace_premium),
            label: l.t('nav_subscription'),
          ),
        ],
      ),
    );
  }
}
