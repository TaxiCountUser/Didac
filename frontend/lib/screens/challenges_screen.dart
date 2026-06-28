import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';

/// Retos / metas — vista del EMPRESARIO. Por cada conductor muestra su progreso
/// en 3 retos escalonados: km recorridos, balance y días de uso. El nivel 1 pide
/// la base (100.000 km / 100.000 € / 300 días); a partir del 2, el doble, y se
/// repite. El siguiente nivel solo aparece cuando la administración aprueba el
/// actual. Cada barra termina en un icono (coche / billete / calendario).
class ChallengesScreen extends StatefulWidget {
  const ChallengesScreen({super.key});

  @override
  State<ChallengesScreen> createState() => _ChallengesScreenState();
}

class _ChallengesScreenState extends State<ChallengesScreen> {
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = DataService().companyChallenges();
  }

  // Icono y unidad de cada reto.
  IconData _icon(String type) => switch (type) {
        'km_100k' => Icons.directions_car,
        'money_100k' => Icons.payments,
        _ => Icons.calendar_month,
      };

  String _unit(AppLocalizations l, String type) => switch (type) {
        'km_100k' => 'km',
        'money_100k' => '€',
        _ => l.t('ch_days_unit'),
      };

  String _label(AppLocalizations l, String type) => switch (type) {
        'km_100k' => l.t('ch_km_label'),
        'money_100k' => l.t('ch_money_label'),
        _ => l.t('ch_days_label'),
      };

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l.t('ch_title'))),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('${l.t('error')}: ${snap.error.toString().replaceFirst('Exception: ', '')}',
                  textAlign: TextAlign.center),
            ));
          }
          final drivers = (((snap.data ?? {})['drivers'] as List?) ?? []).cast<Map<String, dynamic>>();
          if (drivers.isEmpty) {
            return Center(child: Text(l.t('ch_no_drivers')));
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(l.t('ch_intro'), style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 12),
              for (final dr in drivers) _driverCard(l, dr),
            ],
          );
        },
      ),
    );
  }

  Widget _driverCard(AppLocalizations l, Map<String, dynamic> dr) {
    final name = (dr['name'] as String?)?.trim();
    final email = (dr['email'] as String?) ?? '';
    final title = (name != null && name.isNotEmpty) ? name : email;
    final challenges = ((dr['challenges'] as List?) ?? []).cast<Map<String, dynamic>>();
    // El empresario ve aviso si hay un posible error/manipulación de km o dinero.
    final kmSuspicious = dr['km_suspicious'] == true;
    final moneySuspicious = dr['money_suspicious'] == true;
    final maxJump = (dr['max_jump'] as num?)?.toDouble() ?? 0;
    final maxIncome = (dr['max_income'] as num?)?.toDouble() ?? 0;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.person, color: Colors.blueGrey),
                const SizedBox(width: 8),
                Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
              ],
            ),
            const SizedBox(height: 12),
            for (final c in challenges) ...[
              _challengeBar(l, c),
              const SizedBox(height: 14),
            ],
            if (kmSuspicious)
              _warnBox(l.t('ch_km_warn', {'jump': NumberFormat.decimalPattern('es').format(maxJump)})),
            if (moneySuspicious) ...[
              if (kmSuspicious) const SizedBox(height: 6),
              _warnBox(l.t('ch_money_warn', {'amount': NumberFormat.decimalPattern('es').format(maxIncome)})),
            ],
          ],
        ),
      ),
    );
  }

  Widget _warnBox(String text) => Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.orange.shade50,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(Icons.warning_amber, color: Colors.orange, size: 18),
            const SizedBox(width: 6),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 12, color: Colors.deepOrange))),
          ],
        ),
      );

  Widget _challengeBar(AppLocalizations l, Map<String, dynamic> c) {
    final nf = NumberFormat.decimalPattern('es');
    final type = (c['type'] as String?) ?? '';
    final level = (c['level'] as num?)?.toInt() ?? 1;
    final target = (c['target'] as num?)?.toDouble() ?? 0;
    final progress = (c['progress'] as num?)?.toDouble() ?? 0;
    final remaining = (c['remaining'] as num?)?.toDouble() ?? 0;
    final pct = (c['pct'] as num?)?.toDouble() ?? 0;
    final pending = c['pending'] == true;
    final rejected = c['rejected'] == true;
    final unit = _unit(l, type);
    final done = pct >= 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('${_label(l, type)} · ${l.t('ch_level', {'n': '$level'})}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
            Text('${nf.format(progress)} / ${nf.format(target)} $unit',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
        const SizedBox(height: 6),
        // Barra con icono al final (la meta).
        Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: pct,
                  minHeight: 12,
                  backgroundColor: Colors.grey.shade200,
                  color: done ? Colors.green : Colors.amber,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Icon(_icon(type), size: 22, color: done ? Colors.green : Colors.grey.shade500),
          ],
        ),
        const SizedBox(height: 4),
        if (pending)
          Text(l.t('ch_pending'), style: const TextStyle(fontSize: 12, color: Colors.green, fontWeight: FontWeight.w600))
        else if (rejected)
          Text(l.t('ch_rejected'), style: const TextStyle(fontSize: 12, color: Colors.red))
        else
          Text(l.t('ch_remaining', {'x': nf.format(remaining), 'unit': unit}),
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        // Mensaje motivador del premio, distinto según el progreso (color suave).
        Row(
          children: [
            Icon(done ? Icons.celebration : Icons.card_giftcard,
                size: 14, color: done ? Colors.green : Colors.blueGrey.shade300),
            const SizedBox(width: 4),
            Expanded(child: Text(l.t(_motivKey(done, pct)),
                style: TextStyle(
                    fontSize: 12,
                    color: done ? Colors.green : Colors.blueGrey))),
          ],
        ),
      ],
    );
  }

  // Mensaje motivador según el porcentaje de avance del reto.
  String _motivKey(bool done, double pct) {
    if (done) return 'ch_reward_done';
    if (pct >= 0.75) return 'ch_motiv_75';
    if (pct >= 0.50) return 'ch_motiv_50';
    if (pct >= 0.25) return 'ch_motiv_25';
    return 'ch_motiv_0';
  }
}
