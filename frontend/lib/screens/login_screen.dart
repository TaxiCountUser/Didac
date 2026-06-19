import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
        await auth.signInWithPassword(
          email: _email.text.trim(),
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

  @override
  Widget build(BuildContext context) {
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
                    _isSignUp ? 'Crear cuenta de propietario' : 'Iniciar sesión',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    key: const Key('email_field'),
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.email_outlined),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('password_field'),
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Contraseña',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                  ),
                  if (_isSignUp) ...[
                    const SizedBox(height: 16),
                    TextField(
                      key: const Key('company_field'),
                      controller: _company,
                      decoration: const InputDecoration(
                        labelText: 'Nombre de la empresa / flota',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.business_outlined),
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
                          : Text(_isSignUp ? 'Registrarse' : 'Entrar'),
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
                        ? '¿Ya tienes cuenta? Inicia sesión'
                        : '¿Eres propietario? Crea tu cuenta'),
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
