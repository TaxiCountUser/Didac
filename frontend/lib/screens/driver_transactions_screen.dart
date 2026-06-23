import 'package:flutter/material.dart';

import '../models/profile.dart';
import '../services/data_service.dart';
import '../widgets/transaction_tile.dart';
import 'transaction_detail_screen.dart';

enum DriverPeriod { day, week, month, year }

/// Historial de transacciones del driver: lista paginada (scroll infinito)
/// con filtro por día / semana / mes / año. Toca una tarjeta para el detalle.
class DriverTransactionsScreen extends StatefulWidget {
  final Profile profile;
  const DriverTransactionsScreen({super.key, required this.profile});

  @override
  State<DriverTransactionsScreen> createState() => _DriverTransactionsScreenState();
}

class _DriverTransactionsScreenState extends State<DriverTransactionsScreen> {
  static const _pageSize = 20;
  final _service = DataService();
  final _scroll = ScrollController();
  final _items = <Map<String, dynamic>>[];

  DriverPeriod _period = DriverPeriod.day;
  bool _loading = false;
  bool _hasMore = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _reload();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  DateTime get _from {
    final now = DateTime.now();
    switch (_period) {
      case DriverPeriod.day:
        return DateTime(now.year, now.month, now.day);
      case DriverPeriod.week:
        final monday = now.subtract(Duration(days: now.weekday - 1));
        return DateTime(monday.year, monday.month, monday.day);
      case DriverPeriod.month:
        return DateTime(now.year, now.month);
      case DriverPeriod.year:
        return DateTime(now.year);
    }
  }

  DateTime get _to {
    final now = DateTime.now();
    switch (_period) {
      case DriverPeriod.day:
        return _from.add(const Duration(days: 1));
      case DriverPeriod.week:
        return _from.add(const Duration(days: 7));
      case DriverPeriod.month:
        return DateTime(now.year, now.month + 1);
      case DriverPeriod.year:
        return DateTime(now.year + 1);
    }
  }

  Future<void> _reload() async {
    setState(() {
      _items.clear();
      _hasMore = true;
      _error = null;
    });
    await _loadMore();
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 300) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    try {
      final batch = await _service.listTransactions(
        userId: widget.profile.id,
        from: _from,
        to: _to,
        offset: _items.length,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _items.addAll(batch);
        _hasMore = batch.length == _pageSize;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _openDetail(Map<String, dynamic> tx) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TransactionDetailScreen(
          profile: widget.profile,
          transactionId: tx['id'] as String,
        ),
      ),
    );
    if (changed == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mis transacciones')),
      body: Column(
        children: [
          _periodSelector(),
          const Divider(height: 1),
          Expanded(child: _list()),
        ],
      ),
    );
  }

  Widget _periodSelector() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _chip('Día', DriverPeriod.day),
          _chip('Semana', DriverPeriod.week),
          _chip('Mes', DriverPeriod.month),
          _chip('Año', DriverPeriod.year),
        ],
      ),
    );
  }

  Widget _chip(String label, DriverPeriod p) {
    return ChoiceChip(
      label: Text(label),
      selected: _period == p,
      onSelected: (_) {
        setState(() => _period = p);
        _reload();
      },
    );
  }

  Widget _list() {
    if (_error != null && _items.isEmpty) {
      return Center(child: Text('Error: $_error'));
    }
    if (!_loading && _items.isEmpty) {
      return const Center(child: Text('No hay transacciones en este periodo.'));
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        controller: _scroll,
        itemCount: _items.length + (_hasMore ? 1 : 0),
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          if (i >= _items.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final tx = _items[i];
          return TransactionTile(tx: tx, onTap: () => _openDetail(tx));
        },
      ),
    );
  }
}
