import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';

/// Login / registro de Owners.
/// El signUp crea un Owner (el trigger de BD crea su tenant automáticamente).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _company = TextEditingController();

  bool _isSignUp = false;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _company.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final auth = Supabase.instance.client.auth;
    try {
      if (_isSignUp) {
        await auth.signUp(
          email: _email.text.trim(),
          password: _password.text,
          data: {
            'company_name': _company.text.trim(),
            // Sin tenant_id => el trigger lo trata como Owner nuevo.
          },
        );
      } else {
        // Permite entrar con email O con nombre de usuario (sin '@' => usuario).
        var loginEmail = _email.text.trim();
        if (!loginEmail.contains('@')) {
          final mapped = await DataService().emailForUsername(loginEmail);
          if (mapped == null) {
            setState(() => _error = context.l10n.t('login_user_not_found'));
            return;
          }
          loginEmail = mapped;
        }
        await auth.signInWithPassword(
          email: loginEmail,
          password: _password.text,
        );
      }
      // AuthGate reaccionará al cambio de sesión.
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // Inicio de sesión con Google (OAuth de Supabase). En móvil vuelve por deep
  // link; en web redirige en el navegador. Requiere configurar el proveedor
  // Google en Supabase (y un cliente OAuth en Google Cloud).
  Future<void> _googleSignIn() async {
    setState(() { _loading = true; _error = null; });
    try {
      await Supabase.instance.client.auth.signInWithOAuth(
        OAuthProvider.google,
        // En web volvemos SIEMPRE al origen donde corre la app (localhost:8080
        // en pruebas, o el dominio al publicar): así no dependemos de la
        // "Site URL" de Supabase. En móvil volvemos por el deep link.
        redirectTo: kIsWeb ? Uri.base.origin : 'app.taxicount://login-callback',
      );
      // En móvil abre el navegador; el AuthGate reaccionará al volver.
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.local_taxi, size: 72, color: Colors.amber),
                  const SizedBox(height: 16),
                  Text(
                    'TaxiCount',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  Text(
                    _isSignUp ? l.t('login_subtitle_signup') : l.t('login_subtitle_signin'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    key: const Key('email_field'),
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      labelText: _isSignUp ? l.t('login_email') : l.t('login_email_or_user'),
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.email_outlined),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('password_field'),
                    controller: _password,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: l.t('login_password'),
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.lock_outline),
                    ),
                  ),
                  if (_isSignUp) ...[
                    const SizedBox(height: 16),
                    TextField(
                      key: const Key('company_field'),
                      controller: _company,
                      decoration: InputDecoration(
                        labelText: l.t('login_company_fleet'),
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.business_outlined),
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, style: const TextStyle(color: Colors.red)),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _loading ? null : _submit,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: _loading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_isSignUp ? l.t('login_btn_register') : l.t('login_btn_enter')),
                    ),
                  ),
                  TextButton(
                    onPressed: _loading
                        ? null
                        : () => setState(() {
                              _isSignUp = !_isSignUp;
                              _error = null;
                            }),
                    child: Text(_isSignUp
                        ? l.t('login_toggle_to_signin')
                        : l.t('login_toggle_to_signup')),
                  ),
                  const SizedBox(height: 8),
                  Row(children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(l.t('login_or'), style: const TextStyle(color: Colors.grey)),
                    ),
                    const Expanded(child: Divider()),
                  ]),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const Key('google_signin_button'),
                    onPressed: _loading ? null : _googleSignIn,
                    icon: const Icon(Icons.g_mobiledata, size: 28),
                    label: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(l.t('login_with_google')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
