import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';

/// «Corregir kilómetros» (conductor, jefe y autónomo). Para quien apuntó un km de
/// más: ese número pasa a ser el último km del coche y la app ya no deja apuntar
/// menos. Aquí se BAJA o se borra (nunca se sube: los retos de km quedan justos).
/// El conductor ve los suyos; el jefe, los de toda la flota. Todo va por el
/// backend (odometer.js), que impone las reglas y deja cada cambio registrado.
class KmCorrectionScreen extends StatefulWidget {
  final Profile profile;
  const KmCorrectionScreen({super.key, required this.profile});

  @override
  State<KmCorrectionScreen> createState() => _KmCorrectionScreenState();
}

class _KmCorrectionScreenState extends State<KmCorrectionScreen> {
  final _service = DataService();
  List<Map<String, dynamic>>? _entries;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final e = await _service.myOdometerEntries();
      if (mounted) setState(() { _entries = e; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  // Mensaje traducido para los códigos del backend (o el texto tal cual).
  String _errText(AppLocalizations l, Object e) {
    final code = e.toString().replaceFirst('Exception: ', '');
    const known = {'km_not_lower', 'km_below_initial', 'forbidden', 'km_invalid'};
    return known.contains(code) ? l.t('km_fix_err_$code') : '${l.t('error')}: $code';
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _edit(Map<String, dynamic> r) async {
    final l = context.l10n;
    final km = (r['km'] as num?)?.toInt() ?? 0;
    final initial = (r['initial_km'] as num?)?.toInt();
    final ctrl = TextEditingController(text: '$km');
    final newKm = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('km_fix_new')),
        content: TextField(
          controller: ctrl, autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            suffixText: 'km',
            helperText: l.t('km_fix_now', {'km': NumberFormat.decimalPattern().format(km)}),
            helperMaxLines: 3,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.t('cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx,
                int.tryParse(ctrl.text.trim().replaceAll('.', '').replaceAll(',', '')) ?? -1),
            child: Text(l.t('save')),
          ),
        ],
      ),
    );
    if (newKm == null || newKm == km) return;
    // Mismas reglas que el backend, para avisar sin esperar a la red.
    if (newKm < 0) return _toast(l.t('km_fix_err_km_invalid'));
    if (newKm > km) return _toast(l.t('km_fix_err_km_not_lower'));
    if (initial != null && newKm < initial) return _toast(l.t('km_fix_err_km_below_initial'));
    try {
      await _service.correctMyOdometer(r['source'] as String, r['id'] as String, newKm);
      if (!mounted) return;
      _toast(l.t('km_fix_saved'));
      _load();
    } catch (e) {
      if (mounted) _toast(_errText(l, e));
    }
  }

  Future<void> _delete(Map<String, dynamic> r) async {
    final l = context.l10n;
    final isTrip = r['source'] == 'transaction';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(isTrip ? l.t('km_fix_del_trip') : l.t('km_fix_del_reading')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('delete'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _service.correctMyOdometer(r['source'] as String, r['id'] as String, null);
      if (!mounted) return;
      _toast(l.t('km_fix_deleted'));
      _load();
    } catch (e) {
      if (mounted) _toast(_errText(l, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final entries = _entries;
    // El km más alto de cada coche = sus "km actuales" (el que bloquea si está mal).
    final top = <String, String>{};
    final topKm = <String, int>{};
    for (final r in entries ?? const <Map<String, dynamic>>[]) {
      final vid = r['vehicle_id'] as String?;
      final km = (r['km'] as num?)?.toInt() ?? 0;
      if (vid == null) continue;
      if (!topKm.containsKey(vid) || km > topKm[vid]!) { topKm[vid] = km; top[vid] = r['id'] as String; }
    }
    final df = DateFormat('dd/MM/yyyy HH:mm');
    final fmt = NumberFormat.decimalPattern();
    return Scaffold(
      appBar: AppBar(title: Text(l.t('km_fix_title'))),
      body: entries == null
          ? Center(child: _error != null
              ? Padding(padding: const EdgeInsets.all(24), child: Text('${l.t('error')}: $_error', textAlign: TextAlign.center))
              : const CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Icon(Icons.info_outline),
                        const SizedBox(width: 10),
                        Expanded(child: Text(l.t('km_fix_intro'))),
                      ]),
                    ),
                  ),
                  if (entries.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(l.t('km_fix_empty'), textAlign: TextAlign.center),
                    ),
                  for (final r in entries) _row(l, r, top, df, fmt),
                ],
              ),
            ),
    );
  }

  Widget _row(AppLocalizations l, Map<String, dynamic> r, Map<String, String> top,
      DateFormat df, NumberFormat fmt) {
    final km = (r['km'] as num?)?.toInt() ?? 0;
    final at = DateTime.tryParse((r['at'] as String?) ?? '')?.toLocal();
    final isTrip = r['source'] == 'transaction';
    final isTop = top[r['vehicle_id']] == r['id'];
    final who = widget.profile.isOwner ? r['user_name'] as String? : null;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        leading: Icon(isTrip ? Icons.local_taxi : Icons.speed,
            color: isTop ? Colors.amber.shade800 : null),
        title: Text('${fmt.format(km)} km · ${(r['plate'] as String?) ?? '—'}',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text([
          '${isTrip ? l.t('km_fix_src_trip') : l.t('km_fix_src_reading')} · ${at != null ? df.format(at) : '—'}',
          if (who != null) l.t('km_fix_by', {'name': who}),
          if (isTop) l.t('km_fix_current'),
        ].join('\n')),
        isThreeLine: who != null || isTop,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            icon: Icon(Icons.edit, color: scheme.primary),
            tooltip: l.t('km_fix_new'),
            onPressed: () => _edit(r),
          ),
          IconButton(
            icon: Icon(Icons.delete_outline, color: scheme.error),
            tooltip: l.t('delete'),
            onPressed: () => _delete(r),
          ),
        ]),
      ),
    );
  }
}
