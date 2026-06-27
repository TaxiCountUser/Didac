import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';

/// Retos / metas — vista del EMPRESARIO. Muestra, por cada conductor de la
/// empresa, su progreso hacia: 100.000 km, 100.000 € de balance y 300 días de
/// uso. Al cumplirse (con el mínimo de días), el admin revisa y, si procede,
/// regala un mes de suscripción al dueño de la cuenta. Los chóferes no ven esto.
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
          final d = snap.data ?? {};
          final drivers = ((d['drivers'] as List?) ?? []).cast<Map<String, dynamic>>();
          final kmGoal = (d['km_goal'] as num?)?.toDouble() ?? 100000;
          final moneyGoal = (d['money_goal'] as num?)?.toDouble() ?? 100000;
          final daysGoal = (d['days_goal'] as num?)?.toInt() ?? 300;
          final minDays = (d['min_days'] as num?)?.toInt() ?? 300;
          if (drivers.isEmpty) {
            return Center(child: Text(l.t('ch_no_drivers')));
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(l.t('ch_intro'), style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 12),
              for (final dr in drivers)
                _driverCard(l, dr, kmGoal, moneyGoal, daysGoal, minDays),
            ],
          );
        },
      ),
    );
  }

  Widget _driverCard(AppLocalizations l, Map<String, dynamic> dr,
      double kmGoal, double moneyGoal, int daysGoal, int minDays) {
    final name = (dr['name'] as String?)?.trim();
    final email = (dr['email'] as String?) ?? '';
    final title = (name != null && name.isNotEmpty) ? name : email;
    final km = (dr['km'] as num?)?.toDouble() ?? 0;
    final money = (dr['money'] as num?)?.toDouble() ?? 0;
    final days = (dr['active_days'] as num?)?.toInt() ?? 0;
    final maxJump = (dr['max_jump'] as num?)?.toDouble() ?? 0;
    final suspicious = dr['suspicious'] == true;
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
            _bar(l, Icons.speed, l.t('ch_km_title'), km, kmGoal, 'km', days, minDays),
            const SizedBox(height: 12),
            _bar(l, Icons.euro, l.t('ch_money_title'), money, moneyGoal, '€', days, minDays),
            const SizedBox(height: 12),
            _bar(l, Icons.calendar_today, l.t('ch_days_title'), days.toDouble(), daysGoal.toDouble(), l.t('ch_days_unit'), days, minDays),
            if (suspicious) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber, color: Colors.orange, size: 18),
                    const SizedBox(width: 6),
                    Expanded(child: Text(
                      l.t('ch_fraud_warn', {'jump': NumberFormat.decimalPattern('es').format(maxJump)}),
                      style: const TextStyle(fontSize: 12, color: Colors.deepOrange),
                    )),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _bar(AppLocalizations l, IconData icon, String label, double value,
      double goal, String unit, int days, int minDays) {
    final nf = NumberFormat.decimalPattern('es');
    final pct = goal <= 0 ? 0.0 : (value / goal).clamp(0.0, 1.0);
    final reached = value >= goal;
    final daysOk = days >= minDays;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: Colors.amber.shade800),
            const SizedBox(width: 6),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
            if (reached && daysOk) const Icon(Icons.emoji_events, color: Colors.amber, size: 18),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 10,
            backgroundColor: Colors.grey.shade200,
            color: reached ? Colors.green : Colors.amber,
          ),
        ),
        const SizedBox(height: 4),
        Text('${nf.format(value)} $unit / ${nf.format(goal)} $unit  ·  ${(pct * 100).toStringAsFixed(0)}%',
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }
}
