import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../l10n/app_localizations.dart';
import '../services/data_service.dart';

/// Pantalla legal de aceptación OBLIGATORIA (RGPD). Se muestra cuando el perfil
/// tiene legal_accepted_version < kLegalVersion: al registrarse (primer acceso)
/// y, para cuentas antiguas, al abrir la app. Sin aceptar no se puede continuar.
class LegalAcceptScreen extends StatefulWidget {
  final VoidCallback onDone;
  const LegalAcceptScreen({super.key, required this.onDone});

  @override
  State<LegalAcceptScreen> createState() => _LegalAcceptScreenState();
}

class _LegalAcceptScreenState extends State<LegalAcceptScreen> {
  bool _checked = false;
  bool _loading = false;
  String? _error;

  Future<void> _openPolicy() async {
    final uri = Uri.parse('$backendUrl/privacy');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {/* si no se puede abrir, el resumen ya está en pantalla */}
  }

  Future<void> _accept() async {
    setState(() { _loading = true; _error = null; });
    try {
      await DataService().acceptLegal(kLegalVersion);
      widget.onDone();
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.t('legal_title')),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: _loading ? null : () => Supabase.instance.client.auth.signOut(),
            child: Text(l.t('logout'), style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(l.t('legal_intro'), style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 16),
                _point(Icons.badge_outlined, l.t('legal_p_tool')),
                _point(Icons.gps_fixed, l.t('legal_p_gps')),
                _point(Icons.mic_none, l.t('legal_p_voice')),
                _point(Icons.cloud_outlined, l.t('legal_p_providers')),
                _point(Icons.lock_outline, l.t('legal_p_rights')),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  icon: const Icon(Icons.open_in_new, size: 18),
                  onPressed: _openPolicy,
                  label: Text(l.t('legal_read_full')),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CheckboxListTile(
                  value: _checked,
                  onChanged: _loading ? null : (v) => setState(() => _checked = v ?? false),
                  title: Text(l.t('legal_checkbox'), style: const TextStyle(fontSize: 13)),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: (!_checked || _loading) ? null : _accept,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: _loading
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(l.t('legal_accept_btn')),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _point(IconData icon, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: Colors.blueGrey),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
          ],
        ),
      );
}
