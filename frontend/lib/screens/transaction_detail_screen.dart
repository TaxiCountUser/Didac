import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import '../util/format.dart';
import 'transaction_input_screen.dart';

/// Detalle de una transacción. Owner ve conductor + vehículo. Permite
/// editar/eliminar (RLS: owner cualquiera de su tenant; driver solo las suyas).
class TransactionDetailScreen extends StatefulWidget {
  final Profile profile;
  final String transactionId;
  const TransactionDetailScreen({
    super.key,
    required this.profile,
    required this.transactionId,
  });

  @override
  State<TransactionDetailScreen> createState() => _TransactionDetailScreenState();
}

class _TransactionDetailScreenState extends State<TransactionDetailScreen> {
  final _service = DataService();
  Map<String, dynamic>? _tx;
  bool _loading = true;
  String? _error;
  bool _changed = false; // se devuelve al volver, para refrescar la lista

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final tx = await _service.getTransaction(widget.transactionId);
      if (!mounted) return;
      setState(() {
        _tx = tx;
        _loading = false;
        _error = tx == null ? context.l10n.t('td_not_found') : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  bool get _canEdit {
    final tx = _tx;
    if (tx == null) return false;
    return widget.profile.isOwner || tx['user_id'] == widget.profile.id;
  }

  Future<void> _edit() async {
    final tx = _tx!;
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TransactionInputScreen(
          profile: widget.profile,
          editId: widget.transactionId,
          initial: {
            'amount': tx['amount'],
            'category': tx['category'],
            'type': tx['type'],
            'payment_method': tx['payment_method'],
            'description': tx['description'],
            'origin': tx['origin'],
            'destination': tx['destination'],
            'odometer_km': tx['odometer_km'],
            'client_name': tx['client_name'],
            'created_at': tx['created_at'],
            'vehicle_id': tx['vehicle_id'],
          },
        ),
      ),
    );
    if (result == true) {
      _changed = true;
      await _load();
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.t('td_del_title')),
        content: Text(ctx.l10n.t('td_del_msg')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.l10n.t('cancel'))),
          FilledButton(
            key: const Key('confirm_delete_button'),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.l10n.t('delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _service.deleteTransaction(widget.transactionId);
      if (!mounted) return;
      Navigator.of(context).pop(true); // true: lista debe refrescarse
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(context.l10n.t('td_title')),
          actions: [
            if (_canEdit) ...[
              IconButton(
                key: const Key('edit_transaction_button'),
                tooltip: context.l10n.t('edit'),
                icon: const Icon(Icons.edit),
                onPressed: _edit,
              ),
              IconButton(
                key: const Key('delete_transaction_button'),
                tooltip: context.l10n.t('delete'),
                icon: const Icon(Icons.delete),
                onPressed: _delete,
              ),
            ],
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text(_error!))
                : _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    final l = context.l10n;
    final tx = _tx!;
    final type = tx['type'] as String?;
    final amount = (tx['amount'] as num).toDouble();
    final created = parseCreatedAt(tx['created_at']);
    final veh = vehicleLabel(tx);

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Center(
          child: Column(
            children: [
              CircleAvatar(
                radius: 32,
                backgroundColor: typeColor(type).withValues(alpha: 0.15),
                child: Icon(categoryIcon(tx['category'] as String?),
                    color: typeColor(type), size: 32),
              ),
              const SizedBox(height: 12),
              Text(
                '${type == 'income' ? '+' : '-'}${money(amount)}',
                style: TextStyle(
                    fontSize: 36, fontWeight: FontWeight.bold, color: typeColor(type)),
              ),
              Text(type == 'income' ? l.t('td_income') : l.t('td_expense'),
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
        const SizedBox(height: 28),
        if (type == 'income') ..._tripRows(l, tx) else
          _row(Icons.category, l.t('td_category'), l.catLabel(tx['category'] as String?)),
        _row(Icons.calendar_today, l.t('td_datetime'), fmtDateTime(created)),
        _row(
          _payIcon(tx['payment_method'] as String?),
          l.t('td_payment'),
          _payLabel(l, tx['payment_method'] as String?),
        ),
        if ((tx['description'] as String?)?.isNotEmpty == true)
          _row(Icons.notes, l.t('td_desc'), tx['description'] as String),
        if (widget.profile.isOwner)
          _row(Icons.person, l.t('td_driver'), driverName(tx)),
        if (widget.profile.isOwner && veh != null)
          _row(Icons.directions_car, l.t('td_vehicle'), veh),
      ],
    );
  }

  // Datos propios de una carrera (ingreso).
  List<Widget> _tripRows(AppLocalizations l, Map<String, dynamic> tx) {
    final origin = (tx['origin'] as String?)?.trim();
    final destination = (tx['destination'] as String?)?.trim();
    final km = tx['odometer_km'] as int?;
    final client = (tx['client_name'] as String?)?.trim();
    final rows = <Widget>[];
    if ((origin?.isNotEmpty ?? false) || (destination?.isNotEmpty ?? false)) {
      rows.add(_row(Icons.route, l.t('td_route'),
          '${origin?.isNotEmpty == true ? origin : '—'} → ${destination?.isNotEmpty == true ? destination : '—'}'));
    }
    rows.add(_row(Icons.business, l.t('td_client'),
        (client != null && client.isNotEmpty) ? capitalizeFirst(client) : l.t('particular')));
    if (km != null) {
      rows.add(_row(Icons.speed, l.t('td_km'), '$km km'));
    }
    return rows;
  }

  IconData _payIcon(String? pm) => switch (pm) {
        'efectivo' => Icons.payments,
        'bizum' => Icons.smartphone,
        'credito' => Icons.schedule,
        'transferencia' => Icons.account_balance,
        _ => Icons.credit_card,
      };

  String _payLabel(AppLocalizations l, String? pm) => switch (pm) {
        'efectivo' => l.t('ti_cash'),
        'bizum' => l.t('ti_bizum'),
        'credito' => l.t('ti_credit'),
        'transferencia' => l.t('ti_transfer'),
        _ => l.t('ti_card'),
      };

  Widget _row(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Colors.grey),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 2),
                Text(value, style: const TextStyle(fontSize: 16)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
