import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';

/// Retos del propio conductor: su progreso en km y días de uso, con nivel y
/// objetivo actual. Al completar un reto, su jefe gana 1 mes gratis del asiento.
class DriverChallengesScreen extends StatefulWidget {
  const DriverChallengesScreen({super.key});

  @override
  State<DriverChallengesScreen> createState() => _DriverChallengesScreenState();
}

class _DriverChallengesScreenState extends State<DriverChallengesScreen> {
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = DataService().myChallenges();
  }

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
      appBar: AppBar(title: Text(l.t('ch_mine_title'))),
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
          final challenges = (((snap.data ?? {})['challenges'] as List?) ?? []).cast<Map<String, dynamic>>();
          return RefreshIndicator(
            onRefresh: () async => setState(() => _future = DataService().myChallenges()),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(l.t('ch_mine_intro'), style: const TextStyle(color: Colors.grey)),
                const SizedBox(height: 16),
                if (challenges.isEmpty)
                  Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(l.t('ch_mine_empty'))))
                else
                  for (final c in challenges) _challengeCard(l, c),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _challengeCard(AppLocalizations l, Map<String, dynamic> c) {
    final nf = NumberFormat.decimalPattern('es');
    final type = (c['type'] as String?) ?? '';
    final level = (c['level'] as num?)?.toInt() ?? 1;
    final target = (c['target'] as num?)?.toDouble() ?? 0;
    final progress = (c['progress'] as num?)?.toDouble() ?? 0;
    final remaining = (c['remaining'] as num?)?.toDouble() ?? 0;
    final pct = (c['pct'] as num?)?.toDouble() ?? 0;
    final unit = _unit(l, type);
    final done = pct >= 1;
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(_icon(type), color: done ? Colors.green : Colors.amber.shade800),
              const SizedBox(width: 8),
              Expanded(child: Text('${_label(l, type)} · ${l.t('ch_level', {'n': '$level'})}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15))),
              Text('${nf.format(progress)} / ${nf.format(target)} $unit',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ]),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 14,
                backgroundColor: Colors.grey.shade200,
                color: done ? Colors.green : Colors.amber,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              done
                  ? l.t('ch_mine_done')
                  : l.t('ch_remaining', {'x': nf.format(remaining), 'unit': unit}),
              style: TextStyle(fontSize: 12, color: done ? Colors.green : Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
