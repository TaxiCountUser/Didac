import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';

/// Retos / metas del conductor: 100.000 km y 100.000 € de balance, con un
/// mínimo de 300 días de uso. Al cumplirlos, el admin revisa y, si procede,
/// regala un mes de suscripción al dueño de la cuenta.
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
    _future = DataService().myChallenges();
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
          final km = (d['km'] as num?)?.toDouble() ?? 0;
          final money = (d['money'] as num?)?.toDouble() ?? 0;
          final activeDays = (d['active_days'] as num?)?.toInt() ?? 0;
          final kmGoal = (d['km_goal'] as num?)?.toDouble() ?? 100000;
          final moneyGoal = (d['money_goal'] as num?)?.toDouble() ?? 100000;
          final minDays = (d['min_days'] as num?)?.toInt() ?? 300;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(l.t('ch_intro'), style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 8),
              _daysCard(l, activeDays, minDays),
              const SizedBox(height: 16),
              _challengeCard(
                l,
                icon: Icons.speed,
                title: l.t('ch_km_title'),
                value: km,
                goal: kmGoal,
                unit: 'km',
                activeDays: activeDays,
                minDays: minDays,
              ),
              const SizedBox(height: 16),
              _challengeCard(
                l,
                icon: Icons.euro,
                title: l.t('ch_money_title'),
                value: money,
                goal: moneyGoal,
                unit: '€',
                activeDays: activeDays,
                minDays: minDays,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _daysCard(AppLocalizations l, int activeDays, int minDays) {
    final met = activeDays >= minDays;
    return Card(
      child: ListTile(
        leading: Icon(Icons.calendar_today, color: met ? Colors.green : Colors.orange),
        title: Text(l.t('ch_active_days')),
        subtitle: Text(l.t('ch_days_progress', {'n': '$activeDays', 'min': '$minDays'})),
        trailing: met ? const Icon(Icons.check_circle, color: Colors.green) : null,
      ),
    );
  }

  Widget _challengeCard(
    AppLocalizations l, {
    required IconData icon,
    required String title,
    required double value,
    required double goal,
    required String unit,
    required int activeDays,
    required int minDays,
  }) {
    final nf = NumberFormat.decimalPattern('es');
    final pct = goal <= 0 ? 0.0 : (value / goal).clamp(0.0, 1.0);
    final reached = value >= goal;
    final daysOk = activeDays >= minDays;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: Colors.amber.shade800),
                const SizedBox(width: 8),
                Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
                if (reached) const Icon(Icons.emoji_events, color: Colors.amber),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 12,
                backgroundColor: Colors.grey.shade200,
                color: reached ? Colors.green : Colors.amber,
              ),
            ),
            const SizedBox(height: 8),
            Text('${nf.format(value)} $unit / ${nf.format(goal)} $unit  ·  ${(pct * 100).toStringAsFixed(1)}%'),
            const SizedBox(height: 8),
            if (reached && daysOk)
              Text(l.t('ch_reached'), style: const TextStyle(color: Colors.green, fontWeight: FontWeight.w600)),
            if (reached && !daysOk)
              Text(l.t('ch_reached_early'), style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.w600)),
            if (!reached)
              Text(l.t('ch_reward_hint'), style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
