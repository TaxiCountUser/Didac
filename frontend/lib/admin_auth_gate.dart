import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'l10n/app_localizations.dart';
import 'models/profile.dart';
import 'services/data_service.dart';
import 'screens/login_screen.dart';
import 'screens/admin_home_screen.dart';

/// Gate de la app WEB de administración (entry point `main_admin.dart`, separada
/// de la app de operativa). Solo deja pasar a cuentas de admin de plataforma: al
/// resto le muestra un aviso y cierra sesión. Este archivo SÍ importa código admin
/// —es correcto: solo se compila en el build de la app de administración.
class AdminAuthGate extends StatelessWidget {
  const AdminAuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, _) {
        final session = Supabase.instance.client.auth.currentSession;
        if (session == null) return const LoginScreen();
        return const _AdminProfileGate();
      },
    );
  }
}

class _AdminProfileGate extends StatefulWidget {
  const _AdminProfileGate();

  @override
  State<_AdminProfileGate> createState() => _AdminProfileGateState();
}

class _AdminProfileGateState extends State<_AdminProfileGate> {
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
    final l = context.l10n;
    return FutureBuilder<Profile?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final profile = snap.data;
        if (profile != null && profile.isAdmin) {
          return const AdminHomeScreen();
        }
        // Sesión válida pero NO es admin: no puede usar el panel.
        return Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock_outline, size: 64, color: Colors.redAccent),
                    const SizedBox(height: 16),
                    Text(l.t('admin_only_title'),
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    Text(l.t('admin_only_body'), textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                    Wrap(
                      spacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        if (profile == null)
                          FilledButton(onPressed: _reload, child: Text(l.t('err_retry'))),
                        OutlinedButton(
                          onPressed: () => Supabase.instance.client.auth.signOut(),
                          child: Text(l.t('cpw_signout')),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
