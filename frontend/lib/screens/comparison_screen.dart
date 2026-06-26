import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';

/// Comparativa de ingresos/gastos por periodo (día, mes o año), con filtros por
/// conductor y por vehículo. Pensada para comparar meses y años (incluido el
/// histórico importado de Excel).
class ComparisonScreen extends StatefulWidget {
  final Profile profile;
  const ComparisonScreen({super.key, required this.profile});

  @override
  State<ComparisonScreen> createState() => _ComparisonScreenState();
}

enum _Gran { day, month, year }

class _Bucket {
  final String label;
  double income = 0;
  double expense = 0;
  _Bucket(this.label);
  double get balance => income - expense;
}

class _ComparisonScreenState extends State<ComparisonScreen> {
  final _service = DataService();
  _Gran _gran = _Gran.month;
  String? _driverId; // null = todos
  String? _vehicleId; // null = todos
  bool _loading = true;
  String? _error;

  List<Map<String, dynamic>> _drivers = [];
  List<Map<String, dynamic>> _vehicles = [];
  List<_Bucket> _buckets = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final results = await Future.wait([_service.listDrivers(), _service.listVehicles()]);
      _drivers = results[0];
      _vehicles = results[1];
    } catch (_) {/* catálogos best-effort */}
    await _load();
  }

  // Rango a consultar según la granularidad (qué tan atrás miramos).
  DateTime get _from {
    final now = DateTime.now();
    switch (_gran) {
      case _Gran.day:
        return DateTime(now.year, now.month, now.day).subtract(const Duration(days: 30));
      case _Gran.month:
        return DateTime(now.year - 1, now.month, 1); // últimos ~13 meses
      case _Gran.year:
        return DateTime(now.year - 5, 1, 1); // últimos ~6 años
    }
  }

  String _keyFor(DateTime d) {
    switch (_gran) {
      case _Gran.day:
        return '${d.year}-${_pad2(d.month)}-${_pad2(d.day)}';
      case _Gran.month:
        return '${d.year}-${_pad2(d.month)}';
      case _Gran.year:
        return '${d.year}';
    }
  }

  String _labelFor(String key) {
    switch (_gran) {
      case _Gran.day:
        final p = key.split('-');
        return '${p[2]}/${p[1]}';
      case _Gran.month:
        final p = key.split('-');
        const m = ['', 'Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun', 'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic'];
        return '${m[int.parse(p[1])]} ${p[0].substring(2)}';
      case _Gran.year:
        return key;
    }
  }

  String _pad2(int n) => n.toString().padLeft(2, '0');

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _service.statsTransactions(
        driverId: _driverId,
        vehicleId: _vehicleId,
        from: _from,
      );
      // Agrupa en buckets ordenados por clave.
      final map = <String, _Bucket>{};
      for (final r in rows) {
        final created = DateTime.tryParse('${r['created_at']}')?.toLocal();
        if (created == null) continue;
        final key = _keyFor(created);
        final b = map.putIfAbsent(key, () => _Bucket(_labelFor(key)));
        final amt = (r['amount'] is num)
            ? (r['amount'] as num).toDouble()
            : double.tryParse('${r['amount']}') ?? 0;
        if (r['type'] == 'income') {
          b.income += amt;
        } else {
          b.expense += amt;
        }
      }
      final keys = map.keys.toList()..sort();
      _buckets = [for (final k in keys) map[k]!];
      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.t('cmp_title')),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), tooltip: l.t('refresh'), onPressed: _load),
        ],
      ),
      body: Column(
        children: [
          _controls(l),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Text('${l.t('error')}: $_error'))
                    : _buckets.isEmpty
                        ? Center(child: Text(l.t('cmp_no_data')))
                        : _content(l),
          ),
        ],
      ),
    );
  }

  Widget _controls(AppLocalizations l) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          SegmentedButton<_Gran>(
            segments: [
              ButtonSegment(value: _Gran.day, label: Text(l.t('cmp_day'))),
              ButtonSegment(value: _Gran.month, label: Text(l.t('cmp_month'))),
              ButtonSegment(value: _Gran.year, label: Text(l.t('cmp_year'))),
            ],
            selected: {_gran},
            onSelectionChanged: (s) {
              setState(() => _gran = s.first);
              _load();
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String?>(
                  initialValue: _driverId,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: l.t('od_driver'), isDense: true),
                  items: [
                    DropdownMenuItem(value: null, child: Text(l.t('cmp_all'))),
                    for (final d in _drivers)
                      DropdownMenuItem(
                        value: d['id'] as String,
                        child: Text(((d['name'] ?? d['email']) as String?) ?? '—',
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) {
                    setState(() => _driverId = v);
                    _load();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<String?>(
                  initialValue: _vehicleId,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: l.t('od_vehicle'), isDense: true),
                  items: [
                    DropdownMenuItem(value: null, child: Text(l.t('cmp_all'))),
                    for (final v in _vehicles)
                      DropdownMenuItem(
                        value: v['id'] as String,
                        child: Text((v['license_plate'] as String?) ?? '—',
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) {
                    setState(() => _vehicleId = v);
                    _load();
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _content(AppLocalizations l) {
    double totalInc = 0, totalExp = 0;
    for (final b in _buckets) {
      totalInc += b.income;
      totalExp += b.expense;
    }
    final maxY = _buckets.fold<double>(0, (m, b) => [m, b.income, b.expense].reduce((a, c) => a > c ? a : c));
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // Totales del periodo mostrado.
        Card(
          color: Colors.grey.shade100,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _stat(_money(totalInc), l.t('od_kpi_income'), Colors.green),
                _stat(_money(totalExp), l.t('od_kpi_expense'), Colors.red),
                _stat(_money(totalInc - totalExp), l.t('od_kpi_balance'),
                    (totalInc - totalExp) >= 0 ? Colors.green.shade800 : Colors.red),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Leyenda
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _legend(Colors.green, l.t('od_kpi_income')),
            const SizedBox(width: 16),
            _legend(Colors.red, l.t('od_kpi_expense')),
          ],
        ),
        const SizedBox(height: 8),
        // Gráfica de barras (ingresos vs gastos por periodo).
        SizedBox(
          height: 280,
          child: BarChart(
            BarChartData(
              alignment: BarChartAlignment.spaceAround,
              maxY: maxY == 0 ? 1 : maxY * 1.2,
              barTouchData: BarTouchData(enabled: true),
              gridData: const FlGridData(show: true, drawVerticalLine: false),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40)),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 28,
                    getTitlesWidget: (value, meta) {
                      final i = value.toInt();
                      if (i < 0 || i >= _buckets.length) return const SizedBox.shrink();
                      // Si hay muchas barras, muestra una etiqueta de cada N.
                      final step = (_buckets.length / 8).ceil();
                      if (step > 1 && i % step != 0) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(_buckets[i].label, style: const TextStyle(fontSize: 9)),
                      );
                    },
                  ),
                ),
              ),
              barGroups: [
                for (int i = 0; i < _buckets.length; i++)
                  BarChartGroupData(x: i, barRods: [
                    BarChartRodData(toY: _buckets[i].income, color: Colors.green, width: 7),
                    BarChartRodData(toY: _buckets[i].expense, color: Colors.red, width: 7),
                  ]),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Detalle por periodo (balance).
        Text(l.t('cmp_detail'), style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        for (final b in _buckets.reversed)
          Card(
            child: ListTile(
              dense: true,
              title: Text(b.label),
              subtitle: Text('${l.t('od_kpi_income')}: ${_money(b.income)} · ${l.t('od_kpi_expense')}: ${_money(b.expense)}'),
              trailing: Text(_money(b.balance),
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: b.balance >= 0 ? Colors.green.shade800 : Colors.red)),
            ),
          ),
      ],
    );
  }

  Widget _stat(String v, String label, Color color) => Column(
        children: [
          Text(v, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      );

  Widget _legend(Color c, String label) => Row(
        children: [
          Container(width: 12, height: 12, color: c),
          const SizedBox(width: 4),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      );

  String _money(double v) => '${v.toStringAsFixed(2)} €';
}
