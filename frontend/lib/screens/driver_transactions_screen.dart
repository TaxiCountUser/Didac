import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import '../util/format.dart';
import '../widgets/daily_report_sheet.dart';
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
  DateTime _anchor = DateTime.now(); // día/periodo de referencia (seleccionable)
  bool _loading = false;
  bool _hasMore = true;
  String? _error;
  double? _income; // beneficios del periodo (solo ingresos)
  final _searchCtrl = TextEditingController();
  String _search = ''; // empresa o cliente (descripción/origen/destino)

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _reload();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  DateTime get _from {
    final a = _anchor;
    switch (_period) {
      case DriverPeriod.day:
        return DateTime(a.year, a.month, a.day);
      case DriverPeriod.week:
        final monday = a.subtract(Duration(days: a.weekday - 1));
        return DateTime(monday.year, monday.month, monday.day);
      case DriverPeriod.month:
        return DateTime(a.year, a.month);
      case DriverPeriod.year:
        return DateTime(a.year);
    }
  }

  DateTime get _to {
    final a = _anchor;
    switch (_period) {
      case DriverPeriod.day:
        return _from.add(const Duration(days: 1));
      case DriverPeriod.week:
        return _from.add(const Duration(days: 7));
      case DriverPeriod.month:
        return DateTime(a.year, a.month + 1);
      case DriverPeriod.year:
        return DateTime(a.year + 1);
    }
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _anchor,
      firstDate: DateTime(2020),
      lastDate: DateTime(DateTime.now().year + 1, 12, 31),
    );
    if (d != null) {
      setState(() => _anchor = d);
      _reload();
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
        search: _search,
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
      appBar: AppBar(
        title: Text(context.l10n.t('dt_title')),
        actions: [
          TextButton.icon(
            onPressed: _pickDate,
            icon: const Icon(Icons.calendar_today, size: 18),
            label: Text('${_anchor.day.toString().padLeft(2, '0')}/'
                '${_anchor.month.toString().padLeft(2, '0')}'),
          ),
        ],
      ),
      body: Column(
        children: [
          _searchBox(),
          _periodSelector(),
          _earningsBanner(),
          const Divider(height: 1),
          Expanded(child: _list()),
        ],
      ),
    );
  }

  // Buscador por empresa o cliente (también busca en descripción/origen/destino).
  Widget _searchBox() {
    final l = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: TextField(
        controller: _searchCtrl,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          hintText: l.t('dt_search_hint'),
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _search.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _search = '');
                    _reload();
                  },
                ),
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (v) {
          setState(() => _search = v.trim());
          _reload();
        },
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

  // Banner con los beneficios (ingresos) del periodo. Al pulsarlo se abre el
  // informe/desglose del día seleccionado (km, horas, ingresos por método, €/km).
  Widget _earningsBanner() {
    final l = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Material(
        color: const Color(0xFF1B5E20), // verde "ingreso"
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => showDailyReport(context,
              userId: widget.profile.id,
              date: _anchor,
              from: _from,
              to: _to,
              title: _periodTitle(l)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                      Text(l.t('dr_tap_hint'),
                          style: const TextStyle(color: Colors.white60, fontSize: 10)),
                    ],
                  ),
                ),
                Text(
                  _income == null ? '—' : money(_income!),
                  style: const TextStyle(
                      color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.chevron_right, color: Colors.white70),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Título del informe según el periodo seleccionado (día/semana/mes/año).
  String _periodTitle(AppLocalizations l) {
    String dm(DateTime x) =>
        '${x.day.toString().padLeft(2, '0')}/${x.month.toString().padLeft(2, '0')}';
    final base = l.t('dr_summary');
    switch (_period) {
      case DriverPeriod.day:
        return '$base · ${dm(_from)}/${_from.year}';
      case DriverPeriod.week:
        final end = _to.subtract(const Duration(days: 1));
        return '$base · ${dm(_from)} – ${dm(end)}';
      case DriverPeriod.month:
        return '$base · ${_from.month.toString().padLeft(2, '0')}/${_from.year}';
      case DriverPeriod.year:
        return '$base · ${_from.year}';
    }
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
