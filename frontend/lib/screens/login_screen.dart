import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import '../widgets/lang_flag.dart';

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
  final _refCode = TextEditingController(); // código de invitación (opcional)

  bool _isSignUp = false;
  bool _loading = false;
  bool _remember = true; // "Recordarme" (sesión persistente + credenciales)
  bool _showPassword = false; // ojo para ver/ocultar la contraseña
  String? _error;

  // Almacenamiento seguro (cifrado) para la contraseña recordada.
  static const _secure = FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
    _loadRemembered();
  }

  // Recupera la preferencia y, si "Recordarme" está activo, precarga el
  // identificador (prefs) y la contraseña (almacenamiento seguro cifrado).
  Future<void> _loadRemembered() async {
    final prefs = await SharedPreferences.getInstance();
    final remember = prefs.getBool('remember_me') ?? true;
    String id = '';
    String pass = '';
    if (remember) {
      id = prefs.getString('last_login_id') ?? '';
      // En web NO recuperamos la contraseña: el almacenamiento del navegador es
      // débil y la sesión ya se mantiene con el token de Supabase. Solo móvil
      // (Keystore/Keychain) precarga la contraseña recordada.
      if (!kIsWeb) {
        try {
          pass = await _secure.read(key: 'saved_password') ?? '';
        } catch (_) {/* si falla el storage seguro, solo precarga el usuario */}
      }
    }
    if (!mounted) return;
    setState(() {
      _remember = remember;
      _email.text = id;
      _password.text = pass;
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _company.dispose();
    _refCode.dispose();
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
        final res = await auth.signUp(
          email: _email.text.trim(),
          password: _password.text,
          // URL de retorno del correo de confirmación (debe estar permitida en
          // Supabase -> Authentication -> URL Configuration -> Redirect URLs).
          emailRedirectTo: kIsWeb ? _webRedirect() : 'app.taxicount://login-callback',
          data: {
            'company_name': _company.text.trim(),
            // Sin tenant_id => el trigger lo trata como Owner nuevo.
          },
        );
        // Correo ya registrado: Supabase lo devuelve con identities vacío.
        if (res.user != null && (res.user!.identities?.isEmpty ?? false)) {
          setState(() => _error = context.l10n.t('login_email_in_use'));
          return;
        }
        // Código de invitación (opcional): se guarda y se aplica cuando ya
        // exista la empresa (AuthGate), porque /validate necesita el tenant.
        final ref = _refCode.text.trim();
        if (ref.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('pending_referral_code', ref.toUpperCase());
        }
        // Si Supabase exige confirmar el correo, no hay sesión todavía: pasamos
        // a la pantalla de LOGIN con el correo ya puesto y el aviso de confirmar
        // (así, tras confirmar desde el correo, solo tienen que entrar).
        if (res.session == null) {
          setState(() {
            _isSignUp = false;
            _company.clear();
            _refCode.clear();
            _error = context.l10n.t('login_confirm_email_sent');
          });
          return;
        }
      } else {
        // Permite entrar con email O con nombre de usuario (sin '@' => usuario).
        final id = _email.text.trim();
        if (id.contains('@')) {
          await auth.signInWithPassword(email: id, password: _password.text);
        } else {
          // Usuario: el backend resuelve el email y hace el login (P3-01); el
          // email nunca se expone a un cliente sin autenticar.
          await DataService().loginWithUsername(id, _password.text);
        }
      }
      // "Recordarme": guarda identificador (prefs) + contraseña (cifrada) para
      // precargarlos; si está desactivado, borra ambos.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('remember_me', _remember);
      if (_remember) {
        await prefs.setString('last_login_id', _email.text.trim());
        // Solo en móvil guardamos la contraseña (almacenamiento seguro del SO).
        // En web la borramos (por si quedó de una versión anterior) y nunca la
        // escribimos: la sesión persiste con el token de Supabase.
        if (kIsWeb) {
          try { await _secure.delete(key: 'saved_password'); } catch (_) {}
        } else {
          try { await _secure.write(key: 'saved_password', value: _password.text); } catch (_) {}
        }
      } else {
        await prefs.remove('last_login_id');
        try { await _secure.delete(key: 'saved_password'); } catch (_) {}
      }
      // AuthGate reaccionará al cambio de sesión.
    } on AuthException catch (e) {
      setState(() => _error = e.message);
      // Login por EMAIL fallido (no signup): avisa al backend para el log de
      // seguridad (capa B). El login por usuario ya lo registra el servidor.
      if (!_isSignUp && _email.text.trim().contains('@')) {
        DataService().reportAuthFailed('email', email: _email.text.trim(), reason: e.message);
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // Restablecer contraseña: pide el correo y envía el enlace de recuperación.
  // Al abrirlo, la app recibe el evento passwordRecovery y muestra la pantalla
  // para poner una nueva contraseña (main.dart). Requiere el CORREO (no el
  // usuario), porque el enlace se manda por email.
  Future<void> _forgotPassword() async {
    final l = context.l10n;
    final ctrl = TextEditingController(
      text: _email.text.contains('@') ? _email.text.trim() : '',
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('login_forgot')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l.t('login_forgot_msg')),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(labelText: l.t('login_email')),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('login_forgot_send'))),
        ],
      ),
    );
    if (ok != true) return;
    final email = ctrl.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('login_forgot_bademail'))));
      return;
    }
    setState(() => _loading = true);
    try {
      await Supabase.instance.client.auth.resetPasswordForEmail(
        email,
        redirectTo: kIsWeb ? _webRedirect() : 'app.taxicount://login-callback',
      );
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('login_forgot_sent'))));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l.t('error')}: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // URL de retorno en web: origen + carpeta de la app (sin query/fragment).
  // Ej.: https://taxicountuser.github.io/Didac/  o  http://localhost:8080/
  String _webRedirect() {
    final b = Uri.base;
    var path = b.path;
    if (!path.endsWith('/')) {
      path = path.substring(0, path.lastIndexOf('/') + 1);
    }
    return '${b.origin}$path';
  }

  // Inicio de sesión con Google (OAuth de Supabase). En móvil vuelve por deep
  // link; en web redirige en el navegador. Requiere configurar el proveedor
  // Google en Supabase (y un cliente OAuth en Google Cloud).
  Future<void> _googleSignIn() async {
    setState(() { _loading = true; _error = null; });
    try {
      // Android con Client ID configurado: login NATIVO (google_sign_in). El
      // selector de cuenta muestra "TaxiCount", sin la URL de Supabase, y no
      // abre el navegador. Requiere en Google Cloud un OAuth Client de Android
      // (package app.taxicount + SHA-1) y el Web Client ID (kGoogleWebClientId).
      if (!kIsWeb && kGoogleWebClientId.isNotEmpty) {
        final gsi = GoogleSignIn(serverClientId: kGoogleWebClientId);
        // Cierra la sesión de Google en el dispositivo para que SIEMPRE aparezca
        // el selector de cuentas (si no, entra directo con la última usada).
        try { await gsi.signOut(); } catch (_) {}
        final account = await gsi.signIn();
        if (account == null) { // el usuario canceló el selector
          if (mounted) setState(() => _loading = false);
          return;
        }
        final gauth = await account.authentication;
        final idToken = gauth.idToken;
        if (idToken == null) {
          throw const AuthException('No se pudo obtener el token de Google');
        }
        await Supabase.instance.client.auth.signInWithIdToken(
          provider: OAuthProvider.google,
          idToken: idToken,
          accessToken: gauth.accessToken,
        );
        // El AuthGate reacciona al cambio de sesión.
      } else {
        await Supabase.instance.client.auth.signInWithOAuth(
          OAuthProvider.google,
          // En web volvemos a la CARPETA donde corre la app, no solo al dominio:
          // en GitHub Pages la app vive en /Didac/, así que el origen pelado daría
          // una página inexistente. En móvil volvemos por el deep link.
          redirectTo: kIsWeb ? _webRedirect() : 'app.taxicount://login-callback',
        );
        // En móvil abre el navegador; el AuthGate reaccionará al volver.
      }
    } on AuthException catch (e) {
      setState(() => _error = e.message);
      // Login con Google fallido: avisa al backend para el log de seguridad
      // (capa B). Sin email (viene del proveedor OAuth).
      DataService().reportAuthFailed('google', reason: e.message);
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
      body: SafeArea(
        child: Stack(
          children: [
            Center(
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
                    textInputAction: TextInputAction.next,
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
                    obscureText: !_showPassword,
                    // En login, Enter entra directamente; en registro pasa al campo siguiente.
                    textInputAction: _isSignUp ? TextInputAction.next : TextInputAction.done,
                    onSubmitted: (_) {
                      if (!_isSignUp && !_loading) _submit();
                    },
                    decoration: InputDecoration(
                      labelText: l.t('login_password'),
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        tooltip: l.t(_showPassword ? 'login_hide_password' : 'login_show_password'),
                        icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _showPassword = !_showPassword),
                      ),
                    ),
                  ),
                  if (_isSignUp) ...[
                    const SizedBox(height: 16),
                    TextField(
                      key: const Key('company_field'),
                      controller: _company,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) {
                        if (!_loading) _submit();
                      },
                      decoration: InputDecoration(
                        labelText: l.t('login_company_fleet'),
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.business_outlined),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Código de invitación (opcional).
                    TextField(
                      key: const Key('refcode_field'),
                      controller: _refCode,
                      textCapitalization: TextCapitalization.characters,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) {
                        if (!_loading) _submit();
                      },
                      decoration: InputDecoration(
                        labelText: l.t('login_referral_code'),
                        helperText: l.t('login_referral_hint'),
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.card_giftcard_outlined),
                      ),
                    ),
                  ],
                  if (!_isSignUp) ...[
                    const SizedBox(height: 4),
                    CheckboxListTile(
                      key: const Key('remember_me_checkbox'),
                      value: _remember,
                      onChanged: _loading ? null : (v) => setState(() => _remember = v ?? true),
                      title: Text(l.t('login_remember_me')),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
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
                  if (!_isSignUp)
                    TextButton(
                      onPressed: _loading ? null : _forgotPassword,
                      child: Text(l.t('login_forgot')),
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
            // Selector de idioma: bandera arriba a la derecha (no molesta).
            Positioned(
              top: 4,
              right: 4,
              child: PopupMenuButton<String>(
                tooltip: l.t('set_language'),
                icon: LangFlag(localeController.value.languageCode, size: 26),
                onSelected: (code) async {
                  await localeController.setLocale(code);
                  if (mounted) setState(() {});
                },
                itemBuilder: (_) => [
                  for (final entry in kLanguageNames.entries)
                    PopupMenuItem(
                      value: entry.key,
                      child: Row(
                        children: [
                          LangFlag(entry.key, size: 22),
                          const SizedBox(width: 10),
                          Text(entry.value),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
