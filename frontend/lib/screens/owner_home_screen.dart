import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/profile.dart';
import 'vehicles_screen.dart';
import 'drivers_screen.dart';

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
      VehiclesScreen(profile: widget.profile),
      DriversScreen(profile: widget.profile),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(_index == 0 ? 'Vehículos' : 'Conductores'),
        actions: [
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
            icon: Icon(Icons.directions_car_outlined),
            selectedIcon: Icon(Icons.directions_car),
            label: 'Vehículos',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'Conductores',
          ),
        ],
      ),
    );
  }
}
