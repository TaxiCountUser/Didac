import 'dart:io';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/profile.dart';
import '../services/data_service.dart';
import '../util/format.dart';
import '../widgets/transaction_tile.dart';
import 'transaction_detail_screen.dart';

enum Period { today, week, month, custom }

/// Dashboard del Owner: KPIs, gráfico de gastos por categoría, lista de
/// transacciones de toda la flota, filtros combinables y sync en tiempo real.
class OwnerDashboardScreen extends StatefulWidget {
  final Profile profile;
  const OwnerDashboardScreen({super.key, required this.profile});

  @override
  State<OwnerDashboardScreen> createState() => _OwnerDashboardScreenState();
}

class _OwnerDashboardScreenState extends State<OwnerDashboardScreen> {
  static const _pageSize = 20;
  final _service = DataService();
  final _scroll = ScrollController();
  final _items = <Map<String, dynamic>>[];

  // Filtros
  Period _period = Period.month;
  DateTimeRange? _customRange;
  String? _driverId;
  String? _vehicleId;
  String _clientSearch = ''; // buscador por empresa/cliente
  final _searchCtrl = TextEditingController();

  // Catálogos para los dropdowns
  List<Map<String, dynamic>> _drivers = [];
  List<Map<String, dynamic>> _vehicles = [];

  TxSummary _summary = TxSummary.empty();
  bool _loadingPage = false;
  bool _hasMore = true;
  String? _error;
  String? _subStatus; // estado de suscripción del tenant (Fase 4)
  bool _exporting = false; // exportación en curso (Fase 5)

  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadCatalogs();
    _reload();
    _subscribeRealtime();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtrl.dispose();
    final ch = _channel;
    if (ch != null) _service.client.removeChannel(ch);
    super.dispose();
  }

  String? get _client => _clientSearch.trim().isEmpty ? null : _clientSearch.trim();

  // --------------- rango de fechas según el periodo ---------------
  DateTime get _from {
    final now = DateTime.now();
    switch (_period) {
      case Period.today:
        return DateTime(now.year, now.month, now.day);
      case Period.week:
        final monday = now.subtract(Duration(days: now.weekday - 1));
        return DateTime(monday.year, monday.month, monday.day);
      case Period.month:
        return DateTime(now.year, now.month);
      case Period.custom:
        final r = _customRange;
        return r == null ? DateTime(now.year, now.month) : r.start;
    }
  }

  DateTime get _to {
    final now = DateTime.now();
    switch (_period) {
      case Period.today:
        return DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
      case Period.week:
        return _from.add(const Duration(days: 7));
      case Period.month:
        return DateTime(now.year, now.month + 1);
      case Period.custom:
        final r = _customRange;
        return r == null
            ? DateTime(now.year, now.month + 1)
            : DateTime(r.end.year, r.end.month, r.end.day).add(const Duration(days: 1));
    }
  }

  Future<void> _loadCatalogs() async {
    try {
      final drivers = await _service.listDrivers();
      final vehicles = await _service.listVehicles();
      final billing = await _service.fetchTenantBilling(widget.profile.tenantId);
      if (!mounted) return;
      setState(() {
        _drivers = drivers;
        _vehicles = vehicles;
        _subStatus = billing?['subscription_status'] as String?;
      });
    } catch (_) {/* los dropdowns quedan vacíos; no es crítico */}
  }

  bool get _subscriptionActive => _subStatus == 'active' || _subStatus == 'trialing';

  // --------------- carga de datos (KPIs + primera página) ---------------
  Future<void> _reload() async {
    setState(() {
      _items.clear();
      _hasMore = true;
      _error = null;
    });
    await Future.wait([_loadSummary(), _loadMore()]);
  }

  Future<void> _loadSummary() async {
    try {
      final s = await _service.transactionsSummary(
        userId: _driverId,
        vehicleId: _vehicleId,
        from: _from,
        to: _to,
        client: _client,
      );
      if (mounted) setState(() => _summary = s);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 300) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loadingPage || !_hasMore) return;
    setState(() => _loadingPage = true);
    try {
      final batch = await _service.listTransactions(
        userId: _driverId,
        vehicleId: _vehicleId,
        from: _from,
        to: _to,
        client: _client,
        offset: _items.length,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _items.addAll(batch);
        _hasMore = batch.length == _pageSize;
        _loadingPage = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loadingPage = false;
      });
    }
  }

  // --------------- realtime ---------------
  void _subscribeRealtime() {
    final ch = _service.client
        .channel('tx-${widget.profile.tenantId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'transactions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'tenant_id',
            value: widget.profile.tenantId,
          ),
          callback: _onRealtimeInsert,
        )
        .subscribe();
    _channel = ch;
  }

  Future<void> _onRealtimeInsert(PostgresChangePayload payload) async {
    final id = payload.newRecord['id'] as String?;
    if (id == null) return;
    // Recupera la fila con relaciones para mostrar nombre/vehículo.
    Map<String, dynamic>? full;
    try {
      full = await _service.getTransaction(id);
    } catch (_) {}
    full ??= payload.newRecord;
    if (!mounted) return;

    if (_matchesFilters(full)) {
      setState(() {
        _items.insert(0, full!);
        final amount = (full['amount'] as num).toDouble();
        if (full['type'] == 'income') {
          _summary = TxSummary(
            income: _summary.income + amount,
            expense: _summary.expense,
            expenseByCategory: _summary.expenseByCategory,
          );
        } else {
          final cat = (full['category'] as String?) ?? 'otros';
          final byCat = Map<String, double>.from(_summary.expenseByCategory);
          byCat[cat] = (byCat[cat] ?? 0) + amount;
          _summary = TxSummary(
            income: _summary.income,
            expense: _summary.expense + amount,
            expenseByCategory: byCat,
          );
        }
      });
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text('Nuevo registro de ${driverName(full)}'),
      ),
    );
  }

  bool _matchesFilters(Map<String, dynamic> tx) {
    if (_driverId != null && tx['user_id'] != _driverId) return false;
    if (_vehicleId != null && tx['vehicle_id'] != _vehicleId) return false;
    final c = _client;
    if (c != null) {
      final name = (tx['client_name'] as String?)?.toLowerCase() ?? '';
      if (!name.contains(c.toLowerCase())) return false;
    }
    final created = parseCreatedAt(tx['created_at']);
    if (created.isBefore(_from) || !created.isBefore(_to)) return false;
    return true;
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

  // --------------- Exportación (Fase 5) ---------------
  Future<void> _export(String format) async {
    setState(() => _exporting = true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Generando informe ${format == 'excel' ? 'Excel' : 'PDF'}…')),
    );
    try {
      final bytes = await _service.downloadReport(
        format: format,
        from: _from,
        to: _to,
        driverId: _driverId,
        vehicleId: _vehicleId,
        client: _client,
      );
      final dir = await getTemporaryDirectory();
      final ext = format == 'excel' ? 'xlsx' : 'pdf';
      final path =
          '${dir.path}/taxicount_export_${DateTime.now().millisecondsSinceEpoch}.$ext';
      await File(path).writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Informe generado')));
      await OpenFilex.open(path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // --------------- UI ---------------
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (_subStatus != null && !_subscriptionActive) _billingBanner(),
        _toolbar(),
        _searchBar(),
        _filterBar(),
        const Divider(height: 1),
        Expanded(child: _content()),
      ],
    );
  }

  Widget _toolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Row(
        children: [
          Text('Resumen de la flota', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          if (_exporting)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            PopupMenuButton<String>(
              key: const Key('export_menu'),
              icon: const Icon(Icons.download),
              tooltip: 'Exportar',
              onSelected: _export,
              itemBuilder: (_) => const [
                PopupMenuItem(
                  key: Key('export_excel'),
                  value: 'excel',
                  child: ListTile(leading: Icon(Icons.table_chart), title: Text('Exportar Excel')),
                ),
                PopupMenuItem(
                  key: Key('export_pdf'),
                  value: 'pdf',
                  child: ListTile(leading: Icon(Icons.picture_as_pdf), title: Text('Exportar PDF')),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _billingBanner() {
    return Container(
      key: const Key('billing_banner'),
      width: double.infinity,
      color: const Color(0xFFC62828),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: const Row(
        children: [
          Icon(Icons.warning_amber, color: Colors.white, size: 20),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Tu suscripción no está activa. Actualiza tu método de pago para '
              'seguir usando TaxiCount.',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _content() {
    if (_error != null && _items.isEmpty && _summary.income == 0 && _summary.expense == 0) {
      return Center(child: Text('Error: $_error'));
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        controller: _scroll,
        // header (KPIs + chart) + items + posible spinner
        itemCount: 1 + _items.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, i) {
          if (i == 0) return _header();
          final idx = i - 1;
          if (idx >= _items.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final tx = _items[idx];
          return TransactionTile(
            tx: tx,
            showDriver: true,
            onTap: () => _openDetail(tx),
          );
        },
      ),
    );
  }

  Widget _header() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _kpiRow(),
        _expenseChart(),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text('Transacciones', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        if (!_loadingPage && _items.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('No hay transacciones para este filtro.')),
          ),
      ],
    );
  }

  Widget _kpiRow() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          _kpiCard('Ingresos', _summary.income, const Color(0xFF2E7D32),
              Icons.arrow_upward, const Key('kpi_income')),
          const SizedBox(width: 8),
          _kpiCard('Gastos', _summary.expense, const Color(0xFFC62828),
              Icons.arrow_downward, const Key('kpi_expense')),
          const SizedBox(width: 8),
          _kpiCard('Balance', _summary.balance,
              _summary.balance >= 0 ? const Color(0xFF1565C0) : const Color(0xFFC62828),
              Icons.account_balance_wallet, const Key('kpi_balance')),
        ],
      ),
    );
  }

  Widget _kpiCard(String label, double value, Color color, IconData icon, Key key) {
    return Expanded(
      child: Card(
        key: key,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          child: Column(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 6),
              FittedBox(
                child: Text(money(value),
                    style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 16)),
              ),
              const SizedBox(height: 2),
              Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
      ),
    );
  }

  static const _palette = <Color>[
    Color(0xFF1565C0), Color(0xFFC62828), Color(0xFFF9A825), Color(0xFF6A1B9A),
    Color(0xFF00838F), Color(0xFF2E7D32), Color(0xFFEF6C00), Color(0xFF5D4037),
    Color(0xFFAD1457),
  ];

  Widget _expenseChart() {
    final byCat = _summary.expenseByCategory;
    if (byCat.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('Sin gastos en este periodo.')),
      );
    }
    final entries = byCat.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold<double>(0, (s, e) => s + e.value);
    final sections = <PieChartSectionData>[];
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      final pct = total == 0 ? 0 : (e.value / total * 100);
      sections.add(PieChartSectionData(
        color: _palette[i % _palette.length],
        value: e.value,
        title: '${pct.toStringAsFixed(0)}%',
        radius: 70,
        titleStyle: const TextStyle(
            color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
      ));
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Gastos por categoría', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          SizedBox(
            height: 180,
            child: PieChart(PieChartData(sections: sections, centerSpaceRadius: 30)),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              for (var i = 0; i < entries.length; i++)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 12, height: 12, color: _palette[i % _palette.length]),
                    const SizedBox(width: 4),
                    Text('${categoryLabel(entries[i].key)} (${money(entries[i].value)})',
                        style: const TextStyle(fontSize: 12)),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: TextField(
        key: const Key('client_search'),
        controller: _searchCtrl,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Buscar por empresa (p. ej. Gitaxi)',
          prefixIcon: const Icon(Icons.search),
          border: const OutlineInputBorder(),
          suffixIcon: _clientSearch.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _clientSearch = '');
                    _reload();
                  },
                ),
        ),
        onChanged: (v) => setState(() => _clientSearch = v), // refresca el botón limpiar
        onSubmitted: (v) {
          setState(() => _clientSearch = v);
          _reload();
        },
      ),
    );
  }

  Widget _filterBar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          _periodChip('Hoy', Period.today),
          _periodChip('Semana', Period.week),
          _periodChip('Mes', Period.month),
          _periodChip('Personalizado', Period.custom),
          const SizedBox(width: 12),
          _driverDropdown(),
          const SizedBox(width: 8),
          _vehicleDropdown(),
        ],
      ),
    );
  }

  Widget _periodChip(String label, Period p) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: _period == p,
        onSelected: (_) async {
          if (p == Period.custom) {
            final range = await showDateRangePicker(
              context: context,
              firstDate: DateTime(2020),
              lastDate: DateTime(DateTime.now().year + 1, 12, 31),
              initialDateRange: _customRange,
            );
            if (range == null) return;
            setState(() {
              _customRange = range;
              _period = Period.custom;
            });
          } else {
            setState(() => _period = p);
          }
          _reload();
        },
      ),
    );
  }

  Widget _driverDropdown() {
    return DropdownButton<String?>(
      key: const Key('driver_filter'),
      value: _driverId,
      hint: const Text('Conductor'),
      items: [
        const DropdownMenuItem(value: null, child: Text('Todos')),
        for (final d in _drivers)
          DropdownMenuItem(
            value: d['id'] as String,
            child: Text((d['name'] as String?)?.isNotEmpty == true
                ? d['name'] as String
                : d['email'] as String),
          ),
      ],
      onChanged: (v) {
        setState(() => _driverId = v);
        _reload();
      },
    );
  }

  Widget _vehicleDropdown() {
    return DropdownButton<String?>(
      key: const Key('vehicle_filter'),
      value: _vehicleId,
      hint: const Text('Vehículo'),
      items: [
        const DropdownMenuItem(value: null, child: Text('Todos')),
        for (final v in _vehicles)
          DropdownMenuItem(
            value: v['id'] as String,
            child: Text(v['license_plate'] as String? ?? '—'),
          ),
      ],
      onChanged: (v) {
        setState(() => _vehicleId = v);
        _reload();
      },
    );
  }
}
