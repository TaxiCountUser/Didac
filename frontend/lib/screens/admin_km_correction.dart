import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import 'admin_theme.dart';

/// Admin: corregir el km de un conductor. Lista TODO lo que alimenta su odómetro
/// (km inicial del vehículo, lecturas de jornada y km de cada carrera) y deja
/// editar o borrar el que esté mal (auditado en el backend, odometer.js).
/// Se abre desde Retos (reclamación) y desde la ficha de empresa (cada usuario).
/// [onChanged] se llama tras cada corrección (p. ej. para recargar la lista).
Future<void> showAdminKmCorrection(BuildContext context, String userId,
    {VoidCallback? onChanged}) async {
  final l = context.l10n;
  final service = DataService();
  final messenger = ScaffoldMessenger.of(context);
  List<Map<String, dynamic>> readings;
  try {
    readings = await service.adminDriverOdometer(userId);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    return;
  }
  if (!context.mounted) return;
  final df = DateFormat('dd/MM/yyyy HH:mm');
  final fmt = NumberFormat.decimalPattern();

  Future<int?> askKm(int current) {
    final ctrl = TextEditingController(text: '$current');
    return showAdminDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('adm_km_new')),
        content: TextField(
          controller: ctrl, autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: l.t('adm_km_new'), suffixText: 'km'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.t('cancel'))),
          FilledButton(
            onPressed: () {
              final v = int.tryParse(ctrl.text.trim().replaceAll('.', '').replaceAll(',', ''));
              Navigator.pop(ctx, v);
            },
            child: Text(l.t('save')),
          ),
        ],
      ),
    );
  }

  void toastErr(Object e) =>
      messenger.showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));

  Widget row(StateSetter setLocal, Map<String, dynamic> r) {
    final id = r['id'] as String;
    final source = r['source'] as String? ?? 'reading';
    final isTrip = source == 'transaction';
    final isVehicle = source == 'vehicle';
    final km = (r['km'] as num?)?.toInt() ?? 0;
    final at = DateTime.tryParse((r['at'] as String?) ?? '');
    final plate = (r['plate'] as String?) ?? '—';
    final srcLabel = isVehicle
        ? l.t('adm_km_src_vehicle')
        : (isTrip ? l.t('adm_km_src_trip') : l.t('adm_km_src_reading'));
    final srcFg = isVehicle ? AdminColors.purple : (isTrip ? AdminColors.amber : AdminColors.blue);
    final srcBg = isVehicle ? AdminColors.purpleBg : (isTrip ? AdminColors.amberBg : AdminColors.blueBg);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text('${fmt.format(km)} km · $plate',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: AdminColors.text))),
              const SizedBox(width: 6),
              AdminTag(srcLabel, fg: srcFg, bg: srcBg),
            ]),
            Text(at != null ? df.format(at) : '—',
                style: const TextStyle(fontSize: 11, color: AdminColors.muted)),
          ]),
        ),
        IconButton(
          icon: const Icon(Icons.edit, size: 18, color: AdminColors.blue),
          tooltip: l.t('adm_km_new'),
          onPressed: () async {
            final newKm = await askKm(km);
            if (newKm == null || newKm == km) return;
            try {
              if (isVehicle) {
                await service.adminCorrectVehicleOdometer(id, newKm);
              } else if (isTrip) {
                await service.adminCorrectTransactionOdometer(id, newKm);
              } else {
                await service.adminCorrectOdometer(id, newKm);
              }
              r['km'] = newKm;
              setLocal(() {});
              messenger.showSnackBar(SnackBar(content: Text(l.t('adm_km_saved'))));
              onChanged?.call();
            } catch (e) {
              toastErr(e);
            }
          },
        ),
        // El km inicial del vehículo no se borra (solo se corrige).
        if (isVehicle)
          const SizedBox(width: 48)
        else
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 18, color: AdminColors.red),
          tooltip: l.t('adm_km_del_confirm'),
          onPressed: () async {
            final ok = await showAdminDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                // En una carrera solo se borra el km (no la carrera entera).
                content: Text(isTrip ? l.t('adm_km_clear_confirm') : l.t('adm_km_del_confirm')),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.t('cancel'))),
                  FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(l.t('delete'))),
                ],
              ),
            );
            if (ok != true) return;
            try {
              if (isTrip) {
                await service.adminCorrectTransactionOdometer(id, null);
              } else {
                await service.adminDeleteOdometer(id);
              }
              readings.remove(r);
              setLocal(() {});
              messenger.showSnackBar(SnackBar(content: Text(l.t('adm_km_deleted'))));
              onChanged?.call();
            } catch (e) {
              toastErr(e);
            }
          },
        ),
      ]),
    );
  }

  await showAdminDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text(l.t('adm_km_correct_title')),
        content: SizedBox(
          width: 460,
          child: readings.isEmpty
              ? Padding(padding: const EdgeInsets.all(16), child: Text(l.t('adm_km_none')))
              : SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    for (final r in [...readings]) row(setLocal, r),
                  ]),
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.t('close'))),
        ],
      ),
    ),
  );
}
