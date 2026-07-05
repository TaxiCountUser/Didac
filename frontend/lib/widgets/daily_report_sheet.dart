import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import '../util/format.dart';

/// Informe de cierre de jornada (punto 4) y desglose al pulsar el total (punto 5).
/// Muestra km, horas, ingresos por método de pago y €/km.
/// - Modo DÍA (por defecto): pasar solo [date].
/// - Modo PERIODO (semana/mes/año): pasar [from], [to] y [title]; agrega el rango.
Future<void> showDailyReport(
  BuildContext context, {
  String? userId,
  required DateTime date,
  DateTime? from,
  DateTime? to,
  String? title,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _DailyReportBody(
        userId: userId, date: date, from: from, to: to, title: title),
  );
}

String _payLabel(AppLocalizations l, String pm) => switch (pm) {
      'efectivo' => l.t('ti_cash'),
      'tarjeta' => l.t('ti_card'),
      'bizum' => l.t('ti_bizum'),
      'credito' => l.t('ti_credit'),
      'transferencia' => l.t('ti_transfer'),
      _ => l.t('cat_otros'),
    };

IconData _payIcon(String pm) => switch (pm) {
      'efectivo' => Icons.payments,
      'tarjeta' => Icons.credit_card,
      'bizum' => Icons.smartphone,
      'credito' => Icons.schedule,
      'transferencia' => Icons.account_balance,
      _ => Icons.more_horiz,
    };

class _DailyReportBody extends StatefulWidget {
  final String? userId;
  final DateTime date;
  final DateTime? from;
  final DateTime? to;
  final String? title;
  const _DailyReportBody(
      {this.userId, required this.date, this.from, this.to, this.title});

  @override
  State<_DailyReportBody> createState() => _DailyReportBodyState();
}

class _DailyReportBodyState extends State<_DailyReportBody> {
  late Future<DailyReport> _future;

  @override
  void initState() {
    super.initState();
    // Modo periodo si se pasa un rango; si no, informe del día.
    _future = (widget.from != null && widget.to != null)
        ? DataService().periodReport(
            userId: widget.userId, from: widget.from!, to: widget.to!)
        : DataService().dailyReport(userId: widget.userId, date: widget.date);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final nf = NumberFormat.decimalPattern('es');
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: FutureBuilder<DailyReport>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
          }
          if (snap.hasError) {
            return Padding(padding: const EdgeInsets.all(24),
                child: Text('${l.t('error')}: ${snap.error.toString().replaceFirst('Exception: ', '')}'));
          }
          final r = snap.data!;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.summarize, color: Colors.indigo),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      widget.title ??
                          '${l.t('dr_title')} · ${DateFormat('dd/MM/yyyy').format(r.date)}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ]),
              const SizedBox(height: 16),
              // Métricas principales.
              Wrap(spacing: 10, runSpacing: 10, children: [
                _metric(Icons.speed, l.t('dr_km'),
                    r.km == null ? l.t('dr_km_pending') : '${nf.format(r.km!.round())} km', Colors.indigo),
                _metric(Icons.schedule, l.t('dr_hours'),
                    r.hours == null ? '—' : '${r.hours!.toStringAsFixed(1)} h', Colors.teal),
                _metric(Icons.route, l.t('dr_price_km'),
                    r.pricePerKm == null ? '—' : '${money(r.pricePerKm!)}/km', Colors.deepPurple),
              ]),
              const SizedBox(height: 16),
              // Ingresos por método de pago.
              Text(l.t('dr_by_method'), style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              if (r.incomeByMethod.isEmpty)
                Text(l.t('dt_empty'), style: const TextStyle(color: Colors.grey, fontSize: 13))
              else
                ...(r.incomeByMethod.entries.toList()
                      ..sort((a, b) => b.value.compareTo(a.value)))
                    .map((e) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(children: [
                            Icon(_payIcon(e.key), size: 18, color: Colors.blueGrey),
                            const SizedBox(width: 8),
                            Expanded(child: Text(_payLabel(l, e.key))),
                            Text(money(e.value), style: const TextStyle(fontWeight: FontWeight.w600)),
                          ]),
                        )),
              const Divider(height: 24),
              _totalRow(l.t('dr_income'), money(r.income), const Color(0xFF1B5E20)),
              _totalRow(l.t('dr_expense'), money(r.expense), const Color(0xFFC62828)),
              _totalRow(l.t('dr_balance'), money(r.balance),
                  r.balance >= 0 ? const Color(0xFF1B5E20) : const Color(0xFFC62828), bold: true),
              if (r.km == null) ...[
                const SizedBox(height: 10),
                Row(children: [
                  const Icon(Icons.info_outline, size: 16, color: Colors.orange),
                  const SizedBox(width: 6),
                  Expanded(child: Text(l.t('dr_km_hint'),
                      style: const TextStyle(fontSize: 12, color: Colors.orange))),
                ]),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _metric(IconData icon, String label, String value, Color color) => Container(
        width: 150,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: 6),
          Text(value, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: color)),
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ]),
      );

  Widget _totalRow(String label, String value, Color color, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(label,
              style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal))),
          Text(value, style: TextStyle(color: color, fontWeight: FontWeight.bold,
              fontSize: bold ? 18 : 15)),
        ]),
      );
}
