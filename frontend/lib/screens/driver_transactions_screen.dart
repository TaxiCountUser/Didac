import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import '../util/format.dart';
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
  double? _income; // beneficios del periodo (solo ingresos)

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
    _loadEarnings();
    await _loadMore();
  }

  // Beneficios del periodo: SOLO ingresos (carreras), sin restar gastos, que
  // van a cargo de la empresa.
  Future<void> _loadEarnings() async {
    try {
      final s = await _service.transactionsSummary(
        userId: widget.profile.id, from: _from, to: _to);
      if (mounted) setState(() => _income = s.income);
    } catch (_) {/* el banner es best-effort */}
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
      appBar: AppBar(title: Text(context.l10n.t('dt_title'))),
      body: Column(
        children: [
          _periodSelector(),
          _earningsBanner(),
          const Divider(height: 1),
          Expanded(child: _list()),
        ],
      ),
    );
  }

  Widget _periodSelector() {
    final l = context.l10n;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _chip(l.t('per_day'), DriverPeriod.day),
          _chip(l.t('per_week'), DriverPeriod.week),
          _chip(l.t('per_month'), DriverPeriod.month),
          _chip(l.t('per_year'), DriverPeriod.year),
        ],
      ),
    );
  }

  // Banner con los beneficios (ingresos) del periodo seleccionado.
  Widget _earningsBanner() {
    final l = context.l10n;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1B5E20), // verde "ingreso"
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.payments, color: Colors.white, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.t('dt_earnings'),
                    style: const TextStyle(color: Colors.white70, fontSize: 14)),
                Text(l.t('dh_earnings_note'),
                    style: const TextStyle(color: Colors.white60, fontSize: 10)),
              ],
            ),
          ),
          Text(
            _income == null ? '—' : money(_income!),
            style: const TextStyle(
                color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
          ),
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
      return Center(child: Text('${context.l10n.t('error')}: $_error'));
    }
    if (!_loading && _items.isEmpty) {
      return Center(child: Text(context.l10n.t('dt_empty')));
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
