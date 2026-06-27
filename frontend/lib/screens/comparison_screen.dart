import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';

/// Estadísticas por periodo (día, semana, mes o año), con filtros por conductor
/// y por vehículo. Dos métricas: dinero (ingresos/gastos/balance) y km
/// recorridos. Los km se calculan de las lecturas de cuentakilómetros; los días
/// sin lectura se rellenan con el último valor conocido (carry-forward).
class ComparisonScreen extends StatefulWidget {
  final Profile profile;
  const ComparisonScreen({super.key, required this.profile});

  @override
  State<ComparisonScreen> createState() => _ComparisonScreenState();
}

enum _Gran { day, week, month, year }

enum _Metric { money, km }

class _Bucket {
  final String label;
  double income = 0;
  double expense = 0;
  double km = 0;
  _Bucket(this.label);
  double get balance => income - expense;
}

class _ComparisonScreenState extends State<ComparisonScreen> {
  final _service = DataService();
  _Gran _gran = _Gran.month;
  _Metric _metric = _Metric.money;
  String? _driverId; // null = todos
  String? _vehicleId; // null = todos
  DateTime? _customFrom; // rango personalizado (null = usar día/semana/mes/año)
  DateTime? _customTo;
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

  bool get _isCustom => _customFrom != null && _customTo != null;

  _Gran get _effectiveGran {
    if (!_isCustom) return _gran;
    final days = _customTo!.difference(_customFrom!).inDays;
    if (days <= 31) return _Gran.day;
    if (days <= 120) return _Gran.week;
    if (days <= 1100) return _Gran.month;
    return _Gran.year;
  }

  DateTime get _from {
    if (_isCustom) return _customFrom!;
    final now = DateTime.now();
    switch (_gran) {
      case _Gran.day:
        return DateTime(now.year, now.month, now.day).subtract(const Duration(days: 30));
      case _Gran.week:
        return DateTime(now.year, now.month, now.day).subtract(const Duration(days: 84)); // ~12 semanas
      case _Gran.month:
        return DateTime(now.year - 1, now.month, 1); // últimos ~13 meses
      case _Gran.year:
        return DateTime(now.year - 5, 1, 1); // últimos ~6 años
    }
  }

  DateTime? get _to => _isCustom
      ? DateTime(_customTo!.year, _customTo!.month, _customTo!.day).add(const Duration(days: 1))
      : null;

  // Nº de semana (ISO aproximado: semana del año basada en el día del año).
  int _weekOfYear(DateTime d) {
    final firstDay = DateTime(d.year, 1, 1);
    final dayOfYear = d.difference(firstDay).inDays + 1;
    return ((dayOfYear - 1) ~/ 7) + 1;
  }

  String _keyFor(DateTime d) {
    switch (_effectiveGran) {
      case _Gran.day:
        return '${d.year}-${_pad2(d.month)}-${_pad2(d.day)}';
      case _Gran.week:
        return '${d.year}-W${_pad2(_weekOfYear(d))}';
      case _Gran.month:
        return '${d.year}-${_pad2(d.month)}';
      case _Gran.year:
        return '${d.year}';
    }
  }

  String _labelFor(String key) {
    switch (_effectiveGran) {
      case _Gran.day:
        final p = key.split('-');
        return '${p[2]}/${p[1]}';
      case _Gran.week:
        final p = key.split('-W');
        return 'S${p[1]} ${p[0].substring(2)}';
      case _Gran.month:
        final p = key.split('-');
        const m = ['', 'Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun', 'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic'];
        return '${m[int.parse(p[1])]} ${p[0].substring(2)}';
      case _Gran.year:
        return key;
    }
  }

  String _pad2(int n) => n.toString().padLeft(2, '0');

  String _fmtDate(DateTime d) => '${_pad2(d.day)}/${_pad2(d.month)}/${d.year}';

  // Lista ordenada de claves de bucket que abarca [start, end] (paso diario).
  List<String> _bucketKeysInRange(DateTime start, DateTime end) {
    final keys = <String>[];
    final seen = <String>{};
    var d = DateTime(start.year, start.month, start.day);
    final last = DateTime(end.year, end.month, end.day);
    while (!d.isAfter(last)) {
      final k = _keyFor(d);
      if (seen.add(k)) keys.add(k);
      d = d.add(const Duration(days: 1));
    }
    return keys;
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialEntryMode: DatePickerEntryMode.input,
      helpText: context.l10n.t('cmp_custom'),
      initialDateRange: _isCustom
          ? DateTimeRange(start: _customFrom!, end: _customTo!)
          : DateTimeRange(start: DateTime(now.year, now.month, 1), end: now),
    );
    if (picked == null) return;
    setState(() {
      _customFrom = picked.start;
      _customTo = picked.end;
    });
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_metric == _Metric.money) {
        await _loadMoney();
      } else {
        await _loadKm();
      }
      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _loadMoney() async {
    final rows = await _service.statsTransactions(
      driverId: _driverId, vehicleId: _vehicleId, from: _from, to: _to);
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
  }

  Future<void> _loadKm() async {
    final rows = await _service.statsOdometer(driverId: _driverId, vehicleId: _vehicleId, to: _to);
    // Agrupa lecturas por vehículo, ordenadas por fecha.
    final perVehicle = <String, List<MapEntry<DateTime, double>>>{};
    for (final r in rows) {
      final at = DateTime.tryParse('${r['at']}')?.toLocal();
      if (at == null) continue;
      (perVehicle[r['vehicle_id'] as String] ??= []).add(MapEntry(at, (r['km'] as num).toDouble()));
    }
    final start = _from;
    final end = _to ?? DateTime.now();
    final keys = _bucketKeysInRange(start, end);
    final kmByKey = {for (final k in keys) k: 0.0};

    for (final readings in perVehicle.values) {
      readings.sort((a, b) => a.key.compareTo(b.key));
      // Máximo cuentakilómetros observado en cada bucket + baseline previo.
      final maxInBucket = <String, double>{};
      double? baseline; // última lectura ANTES del rango (carry-forward)
      for (final rd in readings) {
        if (rd.key.isBefore(start)) {
          baseline = rd.value;
          continue;
        }
        final k = _keyFor(rd.key);
        final cur = maxInBucket[k];
        if (cur == null || rd.value > cur) maxInBucket[k] = rd.value;
      }
      // Recorre TODOS los buckets en orden; los vacíos heredan el último valor
      // (carry-forward) y aportan 0 km a ese periodo.
      double? last = baseline;
      for (final k in keys) {
        final cur = maxInBucket[k];
        if (cur == null) continue; // sin lectura: 0 km este periodo
        if (last == null) {
          last = cur; // primera lectura conocida: fija el punto de partida
          continue;
        }
        final delta = cur - last;
        if (delta > 0) kmByKey[k] = (kmByKey[k] ?? 0) + delta;
        last = cur;
      }
    }

    // Solo mostramos buckets con km > 0 (o todos si no hay ninguno con datos).
    final entries = keys.where((k) => (kmByKey[k] ?? 0) > 0).toList();
    final useKeys = entries.isEmpty ? <String>[] : entries;
    _buckets = [
      for (final k in useKeys) (_Bucket(_labelFor(k))..km = kmByKey[k] ?? 0),
    ];
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
          // Métrica: dinero o km.
          SegmentedButton<_Metric>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: _Metric.money, label: Text(l.t('cmp_money')), icon: const Icon(Icons.euro, size: 16)),
              ButtonSegment(value: _Metric.km, label: Text(l.t('cmp_km')), icon: const Icon(Icons.speed, size: 16)),
            ],
            selected: {_metric},
            onSelectionChanged: (s) {
              setState(() => _metric = s.first);
              _load();
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SegmentedButton<_Gran>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: _Gran.day, label: Text(l.t('cmp_day'))),
                    ButtonSegment(value: _Gran.week, label: Text(l.t('cmp_week'))),
                    ButtonSegment(value: _Gran.month, label: Text(l.t('cmp_month'))),
                    ButtonSegment(value: _Gran.year, label: Text(l.t('cmp_year'))),
                  ],
                  selected: _isCustom ? <_Gran>{} : {_gran},
                  emptySelectionAllowed: true,
                  onSelectionChanged: (s) {
                    if (s.isEmpty) return;
                    setState(() {
                      _gran = s.first;
                      _customFrom = null;
                      _customTo = null;
                    });
                    _load();
                  },
                ),
              ),
              IconButton(
                tooltip: l.t('cmp_custom'),
                icon: Icon(Icons.date_range, color: _isCustom ? Colors.amber.shade800 : null),
                onPressed: _pickCustomRange,
              ),
            ],
          ),
          if (_isCustom)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: InputChip(
                  label: Text('${_fmtDate(_customFrom!)} – ${_fmtDate(_customTo!)}'),
                  onDeleted: () {
                    setState(() {
                      _customFrom = null;
                      _customTo = null;
                    });
                    _load();
                  },
                ),
              ),
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
    return _metric == _Metric.km ? _kmContent(l) : _moneyContent(l);
  }

  Widget _moneyContent(AppLocalizations l) {
    double totalInc = 0, totalExp = 0;
    for (final b in _buckets) {
      totalInc += b.income;
      totalExp += b.expense;
    }
    final maxY = _buckets.fold<double>(0, (m, b) => [m, b.income, b.expense].reduce((a, c) => a > c ? a : c));
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
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
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _legend(Colors.green, l.t('od_kpi_income')),
            const SizedBox(width: 16),
            _legend(Colors.red, l.t('od_kpi_expense')),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 280,
          child: BarChart(
            BarChartData(
              alignment: BarChartAlignment.spaceAround,
              maxY: maxY == 0 ? 1 : maxY * 1.2,
              barTouchData: BarTouchData(enabled: true),
              gridData: const FlGridData(show: true, drawVerticalLine: false),
              borderData: FlBorderData(show: false),
              titlesData: _titles(),
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

  Widget _kmContent(AppLocalizations l) {
    final totalKm = _buckets.fold<double>(0, (s, b) => s + b.km);
    final maxY = _buckets.fold<double>(0, (m, b) => b.km > m ? b.km : m);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          color: Colors.grey.shade100,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Center(child: _stat('${_km(totalKm)} km', l.t('cmp_total_km'), Colors.indigo)),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 280,
          child: BarChart(
            BarChartData(
              alignment: BarChartAlignment.spaceAround,
              maxY: maxY == 0 ? 1 : maxY * 1.2,
              barTouchData: BarTouchData(enabled: true),
              gridData: const FlGridData(show: true, drawVerticalLine: false),
              borderData: FlBorderData(show: false),
              titlesData: _titles(),
              barGroups: [
                for (int i = 0; i < _buckets.length; i++)
                  BarChartGroupData(x: i, barRods: [
                    BarChartRodData(toY: _buckets[i].km, color: Colors.indigo, width: 10),
                  ]),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(l.t('cmp_detail'), style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        for (final b in _buckets.reversed)
          Card(
            child: ListTile(
              dense: true,
              title: Text(b.label),
              trailing: Text('${_km(b.km)} km',
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.indigo)),
            ),
          ),
      ],
    );
  }

  FlTitlesData _titles() => FlTitlesData(
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
              final step = (_buckets.length / 8).ceil();
              if (step > 1 && i % step != 0) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_buckets[i].label, style: const TextStyle(fontSize: 9)),
              );
            },
          ),
        ),
      );

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

  String _km(double v) => v.toStringAsFixed(0);
}
