import 'package:flutter/material.dart';

import '../util/format.dart';

/// Tarjeta de transacción reutilizable (historial del driver y dashboard).
class TransactionTile extends StatelessWidget {
  final Map<String, dynamic> tx;
  final VoidCallback? onTap;
  final bool showDriver; // el owner ve quién la registró

  const TransactionTile({
    super.key,
    required this.tx,
    this.onTap,
    this.showDriver = false,
  });

  @override
  Widget build(BuildContext context) {
    final type = tx['type'] as String?;
    final amount = (tx['amount'] as num).toDouble();
    final created = parseCreatedAt(tx['created_at']);
    final color = typeColor(type);
    final sign = type == 'income' ? '+' : '-';

    final subtitleParts = <String>[fmtDate(created)];
    if (showDriver) subtitleParts.add(driverName(tx));

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.12),
        child: Icon(categoryIcon(tx['category'] as String?), color: color),
      ),
      title: Text(categoryLabel(tx['category'] as String?)),
      subtitle: Text(subtitleParts.join(' · ')),
      trailing: Text(
        '$sign${money(amount)}',
        style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 16),
      ),
      onTap: onTap,
    );
  }
}
