import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import '../util/format.dart';

/// Ficha detallada de un vehículo (solo Owner): km actuales, estado de ITV,
/// seguro, tarjeta de transporte y revisiones, además de asignar conductores.
/// Es el "mismo sitio donde escoger el conductor" pero ampliado.
class VehicleDetailScreen extends StatefulWidget {
  final Profile profile;
  final Map<String, dynamic> vehicle;
  const VehicleDetailScreen({super.key, required this.profile, required this.vehicle});

  @override
  State<VehicleDetailScreen> createState() => _VehicleDetailScreenState();
}

class _VehicleDetailScreenState extends State<VehicleDetailScreen> {
  final _service = DataService();
  late Map<String, dynamic> _v = Map<String, dynamic>.from(widget.vehicle);
  int? _currentKm;
  bool _loadingKm = true;

  String get _id => _v['id'] as String;

  @override
  void initState() {
    super.initState();
    _loadKm();
  }

  Future<void> _loadKm() async {
    try {
      final km = await _service.lastOdometer(_id);
      if (mounted) setState(() { _currentKm = km; _loadingKm = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingKm = false);
    }
  }

  /// Elimina el vehículo de la flota, con confirmación. Las carreras antiguas se
  /// conservan (el vínculo al coche queda a null), así no se pierden datos.
  Future<void> _confirmDelete() async {
    final l = context.l10n;
    final plate = _v['license_plate'] as String? ?? '—';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('vh_delete')),
        content: Text(l.t('vh_delete_confirm', {'plate': plate})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.t('vh_delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _service.deleteVehicle(_id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('vh_deleted'))));
        Navigator.of(context).pop(); // vuelve a la lista (que recarga)
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l.t('error')}: $e')));
      }
    }
  }

  // ---- helpers de fecha ----
  static DateTime? _date(dynamic v) {
    if (v == null) return null;
    return DateTime.tryParse(v.toString());
  }

  /// Color + texto relativo de una fecha límite (próxima ITV, seguro…).
  (Color, String) _dueStatus(AppLocalizations l, DateTime? due) {
    if (due == null) return (Colors.grey, l.t('vh_no_data'));
    final today = DateTime.now();
    final d0 = DateTime(today.year, today.month, today.day);
    final dd = DateTime(due.year, due.month, due.day);
    final days = dd.difference(d0).inDays;
    if (days < 0) return (Colors.red, '${l.t('vh_overdue')} (${l.t('vh_ago_days', {'n': '${-days}'})})');
    if (days == 0) return (Colors.orange, l.t('vh_today'));
    final color = days <= 30 ? Colors.orange : Colors.green;
    return (color, l.t('vh_in_days', {'n': '$days'}));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final plate = _v['license_plate'] as String? ?? '—';
    final model = _v['model'] as String?;

    final itv = _date(_v['itv_expiry']);
    final taxiItv = _date(_v['taximeter_itv_expiry']);
    final ins = _date(_v['insurance_expiry']);
    final tcDate = _date(_v['transport_card_date']);
    final tcYears = (_v['transport_card_years'] as num?)?.toInt() ?? 4;
    final tcNext = tcDate == null ? null : DateTime(tcDate.year + tcYears, tcDate.month, tcDate.day);
    final interval = (_v['revision_interval_km'] as num?)?.toInt() ?? 15000;
    final lastRev = (_v['last_revision_km'] as num?)?.toInt();
    final notes = _v['maintenance_notes'] as String?;

    return Scaffold(
      appBar: AppBar(
        title: Text('${l.t('vh_detail')} · $plate'),
        actions: [
          IconButton(
            tooltip: l.t('vh_edit_info'),
            icon: const Icon(Icons.edit_outlined),
            onPressed: _editInfo,
          ),
          IconButton(
            tooltip: l.t('vh_delete'),
            icon: const Icon(Icons.delete_outline),
            onPressed: _confirmDelete,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Cabecera: matrícula, modelo y km actuales.
          Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.directions_car)),
              title: Text(plate, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              subtitle: Text(model == null || model.isEmpty ? l.t('vh_no_model') : model),
              trailing: _loadingKm
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(_currentKm == null ? '—' : NumberFormat.decimalPattern('es').format(_currentKm),
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        Text(_currentKm == null ? l.t('vh_km_unknown') : 'km',
                            style: const TextStyle(color: Colors.grey, fontSize: 11)),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(l.t('vh_maintenance'), style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              TextButton.icon(
                onPressed: _editMaintenance,
                icon: const Icon(Icons.edit, size: 18),
                label: Text(l.t('vh_edit_maintenance')),
              ),
            ],
          ),
          _dateCard(l, Icons.fact_check, l.t('vh_itv'), itv),
          _dateCard(l, Icons.speed, l.t('vh_taximeter_itv'), taxiItv),
          _dateCard(l, Icons.shield_outlined, l.t('vh_insurance'), ins),
          _transportCard(l, Icons.badge_outlined, tcDate, tcNext),
          _revisionCard(l, interval, lastRev),
          if (notes != null && notes.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.sticky_note_2_outlined),
                title: Text(l.t('vh_maintenance_notes')),
                subtitle: Text(notes),
              ),
            ),
          ],
          const Divider(height: 32),
          FilledButton.icon(
            onPressed: _assignDrivers,
            icon: const Icon(Icons.people_outline),
            label: Text(l.t('vh_assign_drivers')),
          ),
        ],
      ),
    );
  }

  Widget _dateCard(AppLocalizations l, IconData icon, String title, DateTime? due) {
    final (color, text) = _dueStatus(l, due);
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(title),
        subtitle: Text(due == null ? l.t('vh_no_data') : '${l.t('vh_next')}: ${fmtDate(due)}'),
        trailing: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _transportCard(AppLocalizations l, IconData icon, DateTime? last, DateTime? next) {
    final (color, text) = _dueStatus(l, next);
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(l.t('vh_transport_card')),
        subtitle: Text(last == null
            ? l.t('vh_no_data')
            : '${l.t('vh_date_transport')}: ${fmtDate(last)}\n${l.t('vh_next')}: ${fmtDate(next!)}'),
        isThreeLine: last != null,
        trailing: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _revisionCard(AppLocalizations l, int interval, int? lastRev) {
    final fmt = NumberFormat.decimalPattern('es');
    Color color = Colors.grey;
    String trailing = l.t('vh_no_data');
    String subtitle = '${l.t('vh_revision_interval')}: ${fmt.format(interval)} km';
    if (lastRev != null) {
      final nextKm = lastRev + interval;
      subtitle = '${l.t('vh_km_at_revision')}: ${fmt.format(lastRev)} km\n${l.t('vh_revision_next')}: ${fmt.format(nextKm)} km';
      if (_currentKm != null) {
        final left = nextKm - _currentKm!;
        if (left <= 0) {
          color = Colors.red;
          trailing = l.t('vh_km_over', {'n': fmt.format(-left)});
        } else {
          color = left <= 1000 ? Colors.orange : Colors.green;
          trailing = l.t('vh_km_left', {'n': fmt.format(left)});
        }
      }
    }
    return Card(
      child: ListTile(
        leading: Icon(Icons.build_circle_outlined, color: color),
        title: Text(l.t('vh_revisions')),
        subtitle: Text(subtitle),
        isThreeLine: lastRev != null,
        trailing: Text(trailing, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
      ),
    );
  }

  // ---------------- Corregir matrícula / modelo ----------------
  // Por si el jefe se equivocó al dar de alta el vehículo.
  Future<void> _editInfo() async {
    final l = context.l10n;
    final plateCtrl = TextEditingController(text: _v['license_plate'] as String? ?? '');
    final modelCtrl = TextEditingController(text: _v['model'] as String? ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('vh_edit_info')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: plateCtrl,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(labelText: l.t('vh_plate')),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: modelCtrl,
              decoration: InputDecoration(labelText: l.t('vh_model')),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('save'))),
        ],
      ),
    );
    if (ok != true) return;
    final plate = plateCtrl.text.trim();
    if (plate.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('vh_plate_required'))));
      return;
    }
    try {
      await _service.updateVehicleInfo(_id, licensePlate: plate, model: modelCtrl.text);
      if (mounted) {
        setState(() => _v = {
              ..._v,
              'license_plate': plate,
              'model': modelCtrl.text.trim().isEmpty ? null : modelCtrl.text.trim(),
            });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('vh_info_saved'))));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l.t('error')}: $e')));
    }
  }

  // ---------------- Editar ficha de mantenimiento ----------------
  Future<void> _editMaintenance() async {
    final l = context.l10n;
    DateTime? itv = _date(_v['itv_expiry']);
    DateTime? taxiItv = _date(_v['taximeter_itv_expiry']);
    DateTime? ins = _date(_v['insurance_expiry']);
    DateTime? tc = _date(_v['transport_card_date']);
    final yearsCtrl = TextEditingController(text: '${(_v['transport_card_years'] as num?)?.toInt() ?? 4}');
    final intervalCtrl = TextEditingController(text: '${(_v['revision_interval_km'] as num?)?.toInt() ?? 15000}');
    final lastRevCtrl = TextEditingController(
        text: (_v['last_revision_km'] as num?)?.toInt().toString() ?? '');
    final notesCtrl = TextEditingController(text: _v['maintenance_notes'] as String? ?? '');

    Future<DateTime?> pick(DateTime? initial) => showDatePicker(
          context: context,
          initialDate: initial ?? DateTime.now(),
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        );

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(l.t('vh_edit_maintenance')),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                _dateRow(ctx, l.t('vh_date_itv'), itv, () async {
                  final d = await pick(itv); if (d != null) setLocal(() => itv = d);
                }, () => setLocal(() => itv = null)),
                _dateRow(ctx, l.t('vh_date_taximeter_itv'), taxiItv, () async {
                  final d = await pick(taxiItv); if (d != null) setLocal(() => taxiItv = d);
                }, () => setLocal(() => taxiItv = null)),
                _dateRow(ctx, l.t('vh_date_insurance'), ins, () async {
                  final d = await pick(ins); if (d != null) setLocal(() => ins = d);
                }, () => setLocal(() => ins = null)),
                _dateRow(ctx, l.t('vh_date_transport'), tc, () async {
                  final d = await pick(tc); if (d != null) setLocal(() => tc = d);
                }, () => setLocal(() => tc = null)),
                TextField(
                  controller: yearsCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: l.t('vh_transport_years')),
                ),
                const Divider(height: 24),
                TextField(
                  controller: intervalCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: l.t('vh_revision_interval'), suffixText: 'km'),
                ),
                TextField(
                  controller: lastRevCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l.t('vh_km_at_revision'),
                    suffixText: 'km',
                    helperText: l.t('vh_set_km_hint'),
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: notesCtrl,
                  maxLines: 2,
                  decoration: InputDecoration(labelText: l.t('vh_maintenance_notes')),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('save'))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    String? d(DateTime? x) => x == null ? null : DateFormat('yyyy-MM-dd').format(x);
    final fields = <String, dynamic>{
      'itv_expiry': d(itv),
      'taximeter_itv_expiry': d(taxiItv),
      'insurance_expiry': d(ins),
      'transport_card_date': d(tc),
      'transport_card_years': int.tryParse(yearsCtrl.text.trim()) ?? 4,
      'revision_interval_km': int.tryParse(intervalCtrl.text.trim()) ?? 15000,
      'last_revision_km': int.tryParse(lastRevCtrl.text.trim()),
      'maintenance_notes': notesCtrl.text.trim().isEmpty ? null : notesCtrl.text.trim(),
    };
    try {
      await _service.updateVehicleMaintenance(_id, fields);
      if (mounted) {
        setState(() => _v = {..._v, ...fields});
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('vh_maintenance_saved'))));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l.t('error')}: $e')));
    }
  }

  Widget _dateRow(BuildContext ctx, String label, DateTime? value, VoidCallback onPick, VoidCallback onClear) {
    final l = ctx.l10n;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                Text(value == null ? '—' : fmtDate(value), style: const TextStyle(fontSize: 15)),
              ],
            ),
          ),
          TextButton(onPressed: onPick, child: Text(l.t('vh_pick_date'))),
          if (value != null)
            IconButton(tooltip: l.t('vh_clear'), onPressed: onClear, icon: const Icon(Icons.close, size: 18)),
        ],
      ),
    );
  }

  // ---------------- Asignar conductores ----------------
  Future<void> _assignDrivers() async {
    final l = context.l10n;
    List<Map<String, dynamic>> drivers;
    Set<String> selected;
    try {
      drivers = await _service.listDrivers();
      final assigned = await _service.driversForVehicle(_id);
      selected = assigned.map((d) => d['id'] as String).toSet();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l.t('error')}: $e')));
      return;
    }
    if (!mounted) return;
    if (drivers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('vh_no_drivers'))));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(l.t('vh_drivers_of', {'plate': '${_v['license_plate'] ?? ''}'})),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final dr in drivers)
                  CheckboxListTile(
                    value: selected.contains(dr['id']),
                    title: Text(dr['name'] as String? ?? dr['email'] as String),
                    subtitle: Text(dr['email'] as String),
                    onChanged: (v) => setLocal(() {
                      if (v == true) {
                        selected.add(dr['id'] as String);
                      } else {
                        selected.remove(dr['id']);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('save'))),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        await _service.setDriversForVehicle(
          vehicleId: _id, tenantId: widget.profile.tenantId, userIds: selected.toList());
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('vh_assign_saved'))));
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l.t('error')}: $e')));
      }
    }
  }
}
