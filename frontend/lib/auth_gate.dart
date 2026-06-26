import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models/profile.dart';
import 'models/tenant_state.dart';
import 'services/data_service.dart';
import 'screens/login_screen.dart';
import 'screens/owner_home_screen.dart';
import 'screens/driver_home_screen.dart';
import 'screens/solo_home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/no_fleet_screen.dart';
import 'screens/choose_path_screen.dart';
import 'screens/subscription_gate_screen.dart';
import 'screens/tutorial_gate.dart';

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

/// Perfil + estado de la empresa, cargados juntos para enrutar.
class _Account {
  final Profile profile;
  final TenantState? tenant;
  const _Account(this.profile, this.tenant);
}

class _ProfileRouterState extends State<ProfileRouter> {
  final _service = DataService();
  late Future<_Account?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_Account?> _load() async {
    final p = await _service.fetchMyProfile();
    if (p == null) return null;
    // El estado de la empresa solo aplica si ya pertenece a una flota.
    final t = p.hasFleet ? await _service.fetchMyTenantState(p.tenantId) : null;
    return _Account(p, t);
  }

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Account?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final account = snap.data;
        final profile = account?.profile;
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
        // Tutorial de bienvenida: SOLO la primera vez (flag en BD). Al terminar
        // o saltar, se marca como visto y se recarga.
        if (!profile.tutorialSeen) {
          return TutorialScreen(onFinish: () async {
            await _service.markTutorialSeen();
            _reload();
          });
        }
        // Entró (p. ej. con Google) pero aún no tiene flota: que elija.
        if (!profile.hasFleet) {
          return ChoosePathScreen(onDone: _reload);
        }
        // Prueba de 15 días caducada y sin suscripción activa: bloqueo.
        final tenant = account!.tenant;
        if (tenant != null && !tenant.isUsable) {
          return SubscriptionGateScreen(profile: profile, onChanged: _reload);
        }
        // Modo autónomo: empresa y chófer en uno (conmutador arriba).
        if (tenant != null && tenant.solo) {
          return SoloHomeScreen(profile: profile);
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
