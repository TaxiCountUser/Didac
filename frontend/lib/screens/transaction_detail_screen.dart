import 'package:flutter/material.dart';

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
        _error = tx == null ? 'Transacción no encontrada' : null;
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
        title: const Text('Eliminar transacción'),
        content: const Text('¿Seguro que quieres eliminar esta transacción? Esta acción no se puede deshacer.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(
            key: const Key('confirm_delete_button'),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
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
          title: const Text('Detalle'),
          actions: [
            if (_canEdit) ...[
              IconButton(
                key: const Key('edit_transaction_button'),
                tooltip: 'Editar',
                icon: const Icon(Icons.edit),
                onPressed: _edit,
              ),
              IconButton(
                key: const Key('delete_transaction_button'),
                tooltip: 'Eliminar',
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
              Text(type == 'income' ? 'Ingreso' : 'Gasto',
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
        const SizedBox(height: 28),
        if (type == 'income') ..._tripRows(tx) else
          _row(Icons.category, 'Categoría', categoryLabel(tx['category'] as String?)),
        _row(Icons.calendar_today, 'Fecha y hora', fmtDateTime(created)),
        _row(
          tx['payment_method'] == 'efectivo' ? Icons.payments : Icons.credit_card,
          'Método de pago',
          tx['payment_method'] == 'efectivo' ? 'Efectivo' : 'Tarjeta',
        ),
        if ((tx['description'] as String?)?.isNotEmpty == true)
          _row(Icons.notes, 'Descripción', tx['description'] as String),
        if (widget.profile.isOwner)
          _row(Icons.person, 'Conductor', driverName(tx)),
        if (widget.profile.isOwner && veh != null)
          _row(Icons.directions_car, 'Vehículo', veh),
      ],
    );
  }

  // Datos propios de una carrera (ingreso).
  List<Widget> _tripRows(Map<String, dynamic> tx) {
    final origin = (tx['origin'] as String?)?.trim();
    final destination = (tx['destination'] as String?)?.trim();
    final km = tx['odometer_km'] as int?;
    final client = (tx['client_name'] as String?)?.trim();
    final rows = <Widget>[];
    if ((origin?.isNotEmpty ?? false) || (destination?.isNotEmpty ?? false)) {
      rows.add(_row(Icons.route, 'Trayecto',
          '${origin?.isNotEmpty == true ? origin : '—'} → ${destination?.isNotEmpty == true ? destination : '—'}'));
    }
    rows.add(_row(Icons.business, 'Cliente',
        (client?.isNotEmpty ?? false) ? client! : 'Particular'));
    if (km != null) {
      rows.add(_row(Icons.speed, 'Km del coche', '$km km'));
    }
    return rows;
  }

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
