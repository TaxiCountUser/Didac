import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';

/// M-05: pantalla obligatoria de cambio de contraseña en el primer login.
/// Se muestra cuando el perfil tiene `must_change_password = true` (conductor
/// con contraseña temporal generada/reseteada por el jefe). Al guardar, cambia
/// la contraseña en GoTrue y limpia la marca; luego continúa a la app.
///
/// Con [forced] = false se usa como cambio VOLUNTARIO desde Ajustes: muestra
/// la flecha de volver y oculta el botón de cerrar sesión.
class ChangePasswordScreen extends StatefulWidget {
  final VoidCallback onDone;
  final bool forced;
  const ChangePasswordScreen({super.key, required this.onDone, this.forced = true});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  bool _show = false;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l = context.l10n;
    if (_pass.text.length < 6) {
      setState(() => _error = l.t('cpw_too_short'));
      return;
    }
    if (_pass.text != _confirm.text) {
      setState(() => _error = l.t('cpw_mismatch'));
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      await DataService().changeMyPassword(_pass.text);
      widget.onDone();
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '${l.t('cpw_error')}: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.t('cpw_title')),
        automaticallyImplyLeading: !widget.forced,
        actions: [
          if (widget.forced)
            TextButton(
              onPressed: _loading ? null : () => Supabase.instance.client.auth.signOut(),
              child: Text(l.t('cpw_signout'), style: const TextStyle(color: Colors.white)),
            ),
        ],
      ),
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
                  const Icon(Icons.password, size: 64, color: Colors.amber),
                  const SizedBox(height: 16),
                  Text(l.t(widget.forced ? 'cpw_subtitle' : 'cpw_subtitle_voluntary'),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _pass,
                    obscureText: !_show,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: l.t('cpw_new'),
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _show = !_show),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _confirm,
                    obscureText: !_show,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) { if (!_loading) _save(); },
                    decoration: InputDecoration(
                      labelText: l.t('cpw_confirm'),
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.lock_outline),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, style: const TextStyle(color: Colors.red)),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _loading ? null : _save,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: _loading
                          ? const SizedBox(
                              height: 20, width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(l.t('cpw_save')),
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
