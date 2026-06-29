import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';

/// Pantalla de referidos "Invita y Gana" (programa por hitos).
/// Muestra el código del empresario, su progreso hacia los 5 hitos, el historial
/// de referidos y permite copiar/compartir el código. Solo la ven empresarios/
/// autónomos con suscripción activa (el menú la oculta al resto).
class ReferralScreen extends StatefulWidget {
  final Profile profile;
  const ReferralScreen({super.key, required this.profile});

  @override
  State<ReferralScreen> createState() => _ReferralScreenState();
}

class _ReferralScreenState extends State<ReferralScreen> {
  final _service = DataService();
  late Future<_RefData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_RefData> _load() async {
    final results = await Future.wait([
      _service.referralCode(),
      _service.referralProgress(),
      _service.referralHistory(),
    ]);
    return _RefData(
      code: results[0] as Map<String, dynamic>,
      progress: results[1] as Map<String, dynamic>,
      history: (results[2] as List).cast<Map<String, dynamic>>(),
    );
  }

  void _reload() => setState(() => _future = _load());

  String _shareMessage(String code) => context.l10n.t('ref_share_msg', {'code': code});

  Future<void> _copy(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.t('ref_copied'))));
  }

  Future<void> _share(String code) async {
    // Registra la compartición (límite diario) y abre el diálogo nativo.
    try {
      await _service.referralShare('link');
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().contains('429') || e.toString().toLowerCase().contains('límite')
          ? context.l10n.t('ref_share_limit')
          : '${context.l10n.t('error')}: ${e.toString().replaceFirst('Exception: ', '')}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      return;
    }
    await Share.share(_shareMessage(code));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l.t('set_referral'))),
      body: FutureBuilder<_RefData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return _ErrorView(
              message: snap.error.toString().replaceFirst('Exception: ', ''),
              onRetry: _reload,
            );
          }
          final d = snap.data!;
          if (d.code['eligible'] != true) {
            return _CenteredMsg(icon: Icons.lock_outline, text: l.t('ref_not_eligible'));
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _codeCard(l, d),
                const SizedBox(height: 16),
                _progressCard(l, d),
                const SizedBox(height: 16),
                _milestonesCard(l, d),
                const SizedBox(height: 16),
                _historySection(l, d),
              ],
            ),
          );
        },
      ),
    );
  }

  // --- Tarjeta del código + copiar/compartir ---
  Widget _codeCard(AppLocalizations l, _RefData d) {
    final code = (d.code['code'] as String?) ?? '—';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Icon(Icons.card_giftcard, size: 48, color: Colors.amber),
            const SizedBox(height: 8),
            Text(l.t('ref_explain'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 12),
            Text(l.t('ref_my_code'), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            SelectableText(code,
                style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold, letterSpacing: 3)),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy), label: Text(l.t('ref_copy')),
                  onPressed: () => _copy(code),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  icon: const Icon(Icons.share), label: Text(l.t('ref_share')),
                  onPressed: () => _share(code),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // --- Progreso hacia el siguiente hito ---
  Widget _progressCard(AppLocalizations l, _RefData d) {
    final valid = (d.progress['valid_referrals'] as num?)?.toInt() ?? 0;
    final next = d.progress['next'] as Map<String, dynamic>?;
    final annualDays = (d.progress['annual_days'] as num?)?.toInt() ?? 0;
    final annualMax = (d.progress['annual_max'] as num?)?.toInt() ?? 360;
    final pct = (next != null && (next['required'] as num?) != null && (next['required'] as num) > 0)
        ? (valid / (next['required'] as num)).clamp(0.0, 1.0).toDouble()
        : 1.0;
    final remaining = (next?['remaining'] as num?)?.toInt() ?? 0;
    return Card(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.t('ref_progress', {'n': '$valid'}), style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(value: pct, minHeight: 12, color: Colors.green, backgroundColor: Colors.green.shade100),
            ),
            const SizedBox(height: 8),
            Text(
              next != null
                  ? l.t('ref_next_milestone', {'n': '$remaining', 'days': '${next['days']}'})
                  : l.t('ref_all_done'),
              style: const TextStyle(fontSize: 13, color: Colors.green),
            ),
            const SizedBox(height: 4),
            Text(l.t('ref_annual', {'used': '$annualDays', 'max': '$annualMax'}),
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  // --- Lista de hitos ---
  Widget _milestonesCard(AppLocalizations l, _RefData d) {
    final milestones = ((d.progress['milestones'] as List?) ?? []).cast<Map<String, dynamic>>();
    // El "próximo" hito = primer nivel no alcanzado (se pinta en 🟡).
    final nextLevel = milestones
        .firstWhere((m) => m['reached'] != true, orElse: () => const {})['level'];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            for (final m in milestones) _milestoneTile(l, m, m['level'] == nextLevel),
          ],
        ),
      ),
    );
  }

  Widget _milestoneTile(AppLocalizations l, Map<String, dynamic> m, bool isNext) {
    final required = (m['required'] as num?)?.toInt() ?? 0;
    final days = (m['days'] as num?)?.toInt() ?? 0;
    final reached = m['reached'] == true;
    final IconData icon;
    final Color color;
    if (reached) {
      icon = Icons.check_circle; color = Colors.green;          // ✅ logrado
    } else if (isNext) {
      icon = Icons.hourglass_bottom; color = Colors.amber.shade800; // 🟡 en progreso
    } else {
      icon = Icons.lock_outline; color = Colors.grey;            // 🔒 bloqueado
    }
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color),
      title: Text(l.t('ref_milestone_req', {'n': '$required'})),
      trailing: Text(l.t('ref_milestone_days', {'days': '$days'}),
          style: TextStyle(fontWeight: FontWeight.bold, color: reached ? Colors.green : Colors.grey)),
    );
  }

  // --- Historial ---
  Widget _historySection(AppLocalizations l, _RefData d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.t('ref_history_title'), style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        if (d.history.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(l.t('ref_no_referrals'), style: const TextStyle(color: Colors.grey)),
          )
        else
          for (final r in d.history) _historyTile(l, r),
      ],
    );
  }

  Widget _historyTile(AppLocalizations l, Map<String, dynamic> r) {
    final status = (r['status'] as String?) ?? 'pending';
    final who = ((r['users'] as Map?)?['name'] as String?)
        ?? ((r['users'] as Map?)?['email'] as String?) ?? '—';
    final created = DateTime.tryParse('${r['created_at']}')?.toLocal();
    final dateStr = created != null ? DateFormat('dd/MM/yyyy').format(created) : '';
    final (Color c, String label) = switch (status) {
      'valid' => (Colors.green, l.t('ref_status_valid')),
      'reverted' => (Colors.orange, l.t('ref_status_reverted')),
      'rejected' => (Colors.red, l.t('ref_status_rejected')),
      _ => (Colors.blueGrey, l.t('ref_status_pending')),
    };
    return Card(
      child: ListTile(
        dense: true,
        leading: Icon(Icons.person, color: c),
        title: Text(who, overflow: TextOverflow.ellipsis),
        subtitle: Text(dateStr),
        trailing: Chip(
          label: Text(label, style: const TextStyle(fontSize: 11)),
          backgroundColor: c.withValues(alpha: 0.12),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}

class _RefData {
  final Map<String, dynamic> code;
  final Map<String, dynamic> progress;
  final List<Map<String, dynamic>> history;
  _RefData({required this.code, required this.progress, required this.history});
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off, size: 40, color: Colors.grey),
            const SizedBox(height: 12),
            Text('${l.t('error')}: $message', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: Text(l.t('retry'))),
          ],
        ),
      ),
    );
  }
}

class _CenteredMsg extends StatelessWidget {
  final IconData icon;
  final String text;
  const _CenteredMsg({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
