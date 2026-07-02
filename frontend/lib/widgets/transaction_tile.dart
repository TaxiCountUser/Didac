import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../util/format.dart';

/// Tarjeta de transacción reutilizable (historial del driver y dashboard).
class TransactionTile extends StatelessWidget {
  final Map<String, dynamic> tx;
  final VoidCallback? onTap;
  final bool showDriver; // el owner ve quién la registró
  final bool private; // oculta el importe (modo privacidad)

  const TransactionTile({
    super.key,
    required this.tx,
    this.onTap,
    this.showDriver = false,
    this.private = false,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final type = tx['type'] as String?;
    final amount = (tx['amount'] as num).toDouble();
    final created = parseCreatedAt(tx['created_at']);
    final color = typeColor(type);
    final sign = type == 'income' ? '+' : '-';

    String title;
    if (type == 'income') {
      final c = (tx['client_name'] as String?)?.trim();
      title = (c != null && c.isNotEmpty) ? capitalizeFirst(c) : l.t('particular');
    } else {
      title = l.catLabel(tx['category'] as String?);
    }
    final route = tripRoute(tx);
    // En carreras (servicio) mostramos también la hora; en gastos, solo la fecha.
    final whenStr = type == 'income' ? fmtDateTime(created) : fmtDate(created);
    final subtitleParts = <String>[
      if (route != null) route,
      whenStr,
      if (showDriver) driverName(tx),
    ];
    final pm = (tx['payment_method'] as String?)?.trim();

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.12),
        child: Icon(txIcon(tx), color: color),
      ),
      title: Text(title),
      subtitle: Text(subtitleParts.join(' · ')),
      // Bajo el importe, el método de pago (efectivo/tarjeta/…): más fácil de
      // leer de un vistazo.
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            private ? '••••' : '$sign${money(amount)}',
            style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 16),
          ),
          if (!private && pm != null && pm.isNotEmpty) ...[
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_payMethodIcon(pm), size: 12, color: Colors.grey),
                const SizedBox(width: 3),
                Text(_payMethodLabel(l, pm),
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
          ],
        ],
      ),
      onTap: onTap,
    );
  }
}

/// Etiqueta localizada del método de pago (efectivo/tarjeta/bizum/…).
String _payMethodLabel(AppLocalizations l, String pm) => switch (pm) {
      'efectivo' => l.t('ti_cash'),
      'tarjeta' => l.t('ti_card'),
      'bizum' => l.t('ti_bizum'),
      'credito' => l.t('ti_credit'),
      'transferencia' => l.t('ti_transfer'),
      _ => l.t('cat_otros'),
    };

IconData _payMethodIcon(String pm) => switch (pm) {
      'efectivo' => Icons.payments,
      'tarjeta' => Icons.credit_card,
      'bizum' => Icons.smartphone,
      'credito' => Icons.schedule,
      'transferencia' => Icons.account_balance,
      _ => Icons.more_horiz,
    };
