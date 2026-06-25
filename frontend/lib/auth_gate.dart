import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models/profile.dart';
import 'services/data_service.dart';
import 'screens/login_screen.dart';
import 'screens/owner_home_screen.dart';
import 'screens/driver_home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/no_fleet_screen.dart';

/// Decide qué pantalla mostrar según la sesión y el rol del usuario.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, _) {
        final session = Supabase.instance.client.auth.currentSession;
        if (session == null) return const LoginScreen();
        return const ProfileRouter();
      },
    );
  }
}

/// Carga el perfil y enruta según rol / onboarding.
class ProfileRouter extends StatefulWidget {
  const ProfileRouter({super.key});

  @override
  State<ProfileRouter> createState() => _ProfileRouterState();
}

class _ProfileRouterState extends State<ProfileRouter> {
  final _service = DataService();
  late Future<Profile?> _future;

  @override
  void initState() {
    super.initState();
    _future = _service.fetchMyProfile();
  }

  void _reload() => setState(() => _future = _service.fetchMyProfile());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Profile?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final profile = snap.data;
        if (profile == null) {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('No se pudo cargar el perfil'),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _reload, child: const Text('Reintentar')),
                  TextButton(
                    onPressed: () => Supabase.instance.client.auth.signOut(),
                    child: const Text('Cerrar sesión'),
                  ),
                ],
              ),
            ),
          );
        }

        if (profile.isInactiveDriver) {
          return const NoFleetScreen();
        }
        if (!profile.isOwner) {
          return DriverHomeScreen(profile: profile);
        }
        if (!profile.hasCompletedOnboarding) {
          return OnboardingScreen(profile: profile, onFinished: _reload);
        }
        return OwnerHomeScreen(profile: profile);
      },
    );
  }
}
