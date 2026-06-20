import 'package:flutter/material.dart';

import '../models/profile.dart';
import '../services/data_service.dart';
import '../widgets/transaction_tile.dart';
import 'transaction_detail_screen.dart';

/// Historial de transacciones del driver: lista paginada (scroll infinito)
/// con filtro por mes/año. Toca una tarjeta para ver el detalle.
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

  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
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

  DateTime get _from => _month;
  DateTime get _to => DateTime(_month.year, _month.month + 1);

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

  Future<void> _pickMonth() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _month,
      firstDate: DateTime(2020),
      lastDate: DateTime(DateTime.now().year + 1, 12),
      helpText: 'Selecciona un mes',
      initialDatePickerMode: DatePickerMode.year,
    );
    if (picked != null) {
      setState(() => _month = DateTime(picked.year, picked.month));
      _reload();
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
          _monthSelector(),
          const Divider(height: 1),
          Expanded(child: _list()),
        ],
      ),
    );
  }

  Widget _monthSelector() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Mes anterior',
            icon: const Icon(Icons.chevron_left),
            onPressed: () {
              setState(() => _month = DateTime(_month.year, _month.month - 1));
              _reload();
            },
          ),
          Expanded(
            child: TextButton.icon(
              key: const Key('month_selector'),
              onPressed: _pickMonth,
              icon: const Icon(Icons.calendar_month),
              label: Text(fmtMonth(_month)),
            ),
          ),
          IconButton(
            tooltip: 'Mes siguiente',
            icon: const Icon(Icons.chevron_right),
            onPressed: () {
              setState(() => _month = DateTime(_month.year, _month.month + 1));
              _reload();
            },
          ),
        ],
      ),
    );
  }

  Widget _list() {
    if (_error != null && _items.isEmpty) {
      return Center(child: Text('Error: $_error'));
    }
    if (!_loading && _items.isEmpty) {
      return const Center(child: Text('No hay transacciones este mes.'));
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

String fmtMonth(DateTime d) {
  const months = [
    'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
    'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'
  ];
  final name = months[d.month - 1];
  return '${name[0].toUpperCase()}${name.substring(1)} ${d.year}';
}
