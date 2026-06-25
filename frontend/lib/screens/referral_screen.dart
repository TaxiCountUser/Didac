import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';

/// Programa de referidos: comparte tu código; cuando un compañero se suscribe,
/// ganas un mes gratis. También permite introducir el código de quien te invitó.
class ReferralScreen extends StatefulWidget {
  final Profile profile;
  const ReferralScreen({super.key, required this.profile});

  @override
  State<ReferralScreen> createState() => _ReferralScreenState();
}

class _ReferralScreenState extends State<ReferralScreen> {
  final _service = DataService();
  final _codeCtrl = TextEditingController();
  late final Future<Map<String, int>> _stats = _service.myReferralStats();
  bool _busy = false;
  bool _referred = false; // ya he usado un código

  @override
  void initState() {
    super.initState();
    _referred = widget.profile.referredBy != null;
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final l = context.l10n;
    if (_codeCtrl.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      await _service.setMyReferrer(_codeCtrl.text.trim());
      if (!mounted) return;
      setState(() => _referred = true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('ref_applied'))));
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().replaceFirst('Exception: ', '');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l.t('error')}: $msg')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final code = widget.profile.referralCode ?? '—';
    return Scaffold(
      appBar: AppBar(title: Text(l.t('ref_title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Icon(Icons.card_giftcard, size: 64, color: Colors.amber),
          const SizedBox(height: 12),
          Text(l.t('ref_explain'),
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 24),
          // Mi código
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(l.t('ref_my_code'), style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 6),
                  SelectableText(
                    code,
                    style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold, letterSpacing: 3),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.copy),
                        label: Text(l.t('ref_copy')),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: code));
                          ScaffoldMessenger.of(context)
                              .showSnackBar(SnackBar(content: Text(l.t('ref_copied'))));
                        },
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        icon: const Icon(Icons.share),
                        label: Text(l.t('ref_share')),
                        onPressed: () {
                          final msg = l.t('ref_share_msg', {'code': code});
                          Clipboard.setData(ClipboardData(text: msg));
                          ScaffoldMessenger.of(context)
                              .showSnackBar(SnackBar(content: Text(l.t('ref_copied'))));
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Estadísticas
          FutureBuilder<Map<String, int>>(
            future: _stats,
            builder: (context, snap) {
              final s = snap.data ?? const {'total': 0, 'rewarded': 0};
              return Card(
                color: Colors.green.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _stat('${s['total'] ?? 0}', l.t('ref_invited')),
                      _stat('${s['rewarded'] ?? 0}', l.t('ref_paying')),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 24),
          // Introducir el código de quien me invitó
          if (_referred)
            Card(
              child: ListTile(
                leading: const Icon(Icons.check_circle, color: Colors.green),
                title: Text(l.t('ref_already')),
              ),
            )
          else ...[
            Text(l.t('ref_have_code'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _codeCtrl,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      labelText: l.t('ref_enter_code'),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _apply,
                  child: _busy
                      ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(l.t('ref_apply')),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _stat(String v, String label) => Column(
        children: [
          Text(v, style: Theme.of(context).textTheme.headlineSmall),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
}
