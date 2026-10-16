import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import '../util/day_vehicle.dart';
import '../util/format.dart';
import '../util/km_warning.dart';
import 'agenda_input_screen.dart';
import 'km_correction_screen.dart';
import 'voice_input_screen.dart';

const kCategories = <String, String>{
  'gasolina': 'Gasolina',
  'gasoil': 'Gasoil',
  'carga_electrica': 'Carga eléctrica',
  'taller': 'Taller',
  'peaje': 'Peaje',
  'parking': 'Parking',
  'lavado': 'Lavado',
  'seguro': 'Seguro',
  'autonomos': 'Autónomos (TGSS)',
  'seguridad_social': 'Seg. Social conductores',
  'compra': 'Compra',
  'ingreso_tarjeta': 'Ingreso',
  'otros': 'Otros',
};

/// Entrada de transacción: carrera (ingreso) o gasto, manual o como
/// previsualización de un parseo de voz.
///
/// - Carrera (income): precio + origen, destino, km (opcional), cliente/empresa.
/// - Gasto (expense): importe + categoría.
class TransactionInputScreen extends StatefulWidget {
  final Profile profile;
  final Map<String, dynamic>? initial; // valores parseados (modo preview)
  final bool isPreview;
  final String? editId; // si != null, edita la transacción existente
  final bool embedded; // si true, no envuelve en Scaffold (para pestañas)
  // Si true, al crear una carrera nueva vuelve a la pantalla anterior con
  // Navigator.pop(true) en vez de ir a home (para registrar desde la agenda).
  final bool popWithResult;
  const TransactionInputScreen({
    super.key,
    required this.profile,
    this.initial,
    this.isPreview = false,
    this.editId,
    this.embedded = false,
    this.popWithResult = false,
  });

  @override
  State<TransactionInputScreen> createState() => _TransactionInputScreenState();
}

class _TransactionInputScreenState extends State<TransactionInputScreen> {
  final _amount = TextEditingController();
  final _description = TextEditingController();
  final _origin = TextEditingController();
  final _destination = TextEditingController();
  final _km = TextEditingController();
  final _client = TextEditingController();
  String? _category;
  String _type = 'income'; // por defecto, carrera
  String _payment = 'tarjeta';
  late DateTime _when; // fecha y hora del registro (por defecto, ahora)
  int? _utcOffsetMin; // al EDITAR: la diferencia horaria de la carrera (mig. 091)
  bool _saving = false;

  // Vehículos asignados al conductor (para imputar el coche).
  List<Map<String, dynamic>> _vehicles = const [];
  String? _vehicleId;
  bool _vehiclesLoaded = false;
  // Intentó guardar sin coche (con varios): el campo se pinta en rojo.
  bool _vehicleMissing = false;
  final _vehicleFieldKey = GlobalKey();
  // Último km registrado del vehículo seleccionado (para validar que no baje).
  int? _lastKm;
  // Agenda (oculta y de pago): si el admin la activó, aparece el 3er segmento.
  bool _agendaEnabled = false;

  // ¿Puede elegir el coche? El conductor siempre; el jefe en lo que apunta él
  // (nuevo o suyo), no al editar la carrera de otro conductor.
  bool get _canPickVehicle =>
      !widget.profile.isOwner || widget.editId == null || widget.initial?['user_id'] == widget.profile.id;

  @override
  void initState() {
    super.initState();
    _when = DateTime.now();
    if (_canPickVehicle) _loadVehicles();
    if (widget.editId == null) _loadAgendaFlag(); // el 3er segmento solo al crear
    final i = widget.initial;
    if (i != null) {
      if (i['amount'] != null) _amount.text = (i['amount']).toString();
      _category = kCategories.containsKey(i['category']) ? i['category'] as String? : null;
      _type = (i['type'] as String?) ?? 'income';
      _payment = (i['payment_method'] as String?) ?? 'tarjeta';
      if (i['description'] != null) _description.text = i['description'] as String;
      if (i['origin'] != null) _origin.text = i['origin'] as String;
      if (i['destination'] != null) _destination.text = i['destination'] as String;
      if (i['odometer_km'] != null) _km.text = (i['odometer_km']).toString();
      if (i['client_name'] != null) _client.text = i['client_name'] as String;
      // Hora tal como se apuntó (una carrera de México se edita en hora de México).
      if (i['created_at'] != null) _when = txWallTime(i);
      final off = i['utc_offset_min'];
      if (off is num) _utcOffsetMin = off.toInt();
    }
  }

  // Coche preseleccionado (registro nuevo): el del día (al «Iniciar día»), si no
  // el elegido hoy en la primera carrera, si no el último que usó, si no su único
  // coche. Si tiene VARIOS y no ha iniciado el día con uno, se le avisa y elige.
  Future<void> _loadVehicles() async {
    try {
      final vs = await DataService().myVehicles();
      bool has(String? id) => id != null && vs.any((v) => v['id'] == id);
      String? todays, dayVid, lastVid;
      if (widget.editId == null) {
        todays = await DataService().todaysVehicleId(widget.profile.id);
        if (!has(todays)) dayVid = await getDayVehicle(widget.profile.id);
        if (!has(todays) && !has(dayVid)) lastVid = await DataService().lastUsedVehicleId(widget.profile.id);
      }
      if (!mounted) return;
      setState(() {
        _vehicles = vs;
        _vehiclesLoaded = true;
        final initVid = widget.initial?['vehicle_id'] as String?;
        if (has(initVid)) {
          _vehicleId = initVid;
        } else if (has(todays)) {
          _vehicleId = todays; // el coche con el que inició el día
        } else if (has(dayVid)) {
          _vehicleId = dayVid; // el que eligió hoy en la primera carrera
        } else if (has(lastVid)) {
          _vehicleId = lastVid; // el último que usó
        } else if (vs.length == 1) {
          _vehicleId = vs.first['id'] as String?;
        }
      });
      _loadLastKm();
      if (widget.editId == null && vs.length > 1 && !has(todays) && !has(dayVid)) {
        await _askDayVehicle();
      }
    } catch (_) {
      if (mounted) setState(() => _vehiclesLoaded = true);
    }
  }

  // Aviso «No has iniciado el día con un coche»: elige con cuál trabaja hoy (el
  // último usado ya marcado). Se recuerda hasta medianoche: no vuelve a salir.
  Future<void> _askDayVehicle() async {
    if (!mounted) return;
    final l = context.l10n;
    String? sel = _vehicleId;
    final picked = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          icon: const Icon(Icons.directions_car),
          title: Text(l.t('ti_day_vehicle_title')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.t('ti_day_vehicle_body')),
                const SizedBox(height: 8),
                for (final v in _vehicles)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(sel == v['id'] ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                        color: sel == v['id'] ? Theme.of(ctx).colorScheme.primary : null),
                    title: Text(_vehicleLabel(v)),
                    onTap: () => setD(() => sel = v['id'] as String),
                  ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: sel == null ? null : () => Navigator.pop(ctx, sel),
              child: Text(l.t('ti_day_vehicle_ok')),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await setDayVehicle(widget.profile.id, picked);
    if (!mounted) return;
    setState(() => _vehicleId = picked);
    _loadLastKm();
  }

  /// Carga el último km registrado del vehículo seleccionado, para impedir que
  /// se guarde una lectura inferior (no se puede "desandar" el cuentakilómetros).
  Future<void> _loadLastKm() async {
    final vid = _vehicleId;
    if (vid == null) {
      if (mounted) setState(() => _lastKm = null);
      return;
    }
    try {
      final k = await DataService().lastOdometer(vid, excludeTxId: widget.editId);
      if (mounted) setState(() => _lastKm = k);
    } catch (_) {
      // Sin conexión: no bloqueamos por no poder comprobar.
    }
  }

  /// null si se puede apuntar la carrera; si no, el motivo (sin jornada / en pausa).
  /// Ante un fallo de red no bloquea (nunca se pierde una carrera por eso).
  Future<String?> _workdayBlock(AppLocalizations l) async {
    try {
      final svc = DataService();
      if (!await svc.isWorkdayRequired(widget.profile.tenantId)) return null;
      final st = (await svc.currentShift(widget.profile.id))?['status'];
      if (st == 'open') return null;
      return l.t(st == 'paused' ? 'wd_block_paused' : 'wd_block_start');
    } catch (_) {
      return null;
    }
  }

  /// Abre «Corregir kilómetros» y, al volver, recarga el último km.
  Future<void> _openKmFix() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => KmCorrectionScreen(profile: widget.profile)));
    if (mounted) _loadLastKm();
  }

  /// Devuelve el mensaje de error de los km (o null si son válidos).
  String? _kmError(AppLocalizations l) {
    if (!_isTrip) return null;
    final txt = _km.text.trim();
    if (txt.isEmpty) return null;
    final km = int.tryParse(txt);
    if (km == null) return l.t('ti_invalid_km');
    if (_lastKm != null && km < _lastKm!) {
      return l.t('ti_km_too_low', {'last': _lastKm.toString()});
    }
    return null;
  }

  String _vehicleLabel(Map<String, dynamic> v) {
    final plate = (v['license_plate'] as String?) ?? '';
    final model = (v['model'] as String?) ?? '';
    if (plate.isNotEmpty && model.isNotEmpty) return '$plate · $model';
    return plate.isNotEmpty ? plate : (model.isNotEmpty ? model : 'Vehículo');
  }

  Future<void> _pickWhen() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _when,
      firstDate: DateTime(2020),
      lastDate: DateTime(DateTime.now().year + 1, 12, 31),
      helpText: 'Fecha del registro',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_when),
      helpText: 'Hora del registro',
    );
    if (!mounted) return;
    setState(() {
      _when = DateTime(
        date.year, date.month, date.day,
        time?.hour ?? _when.hour, time?.minute ?? _when.minute,
      );
    });
  }

  @override
  void dispose() {
    _amount.dispose();
    _description.dispose();
    _origin.dispose();
    _destination.dispose();
    _km.dispose();
    _client.dispose();
    super.dispose();
  }

  bool get _isTrip => _type == 'income';

  Future<void> _loadAgendaFlag() async {
    final on = await DataService().isAgendaEnabled(widget.profile.tenantId);
    if (mounted && on) setState(() => _agendaEnabled = true);
  }

  // Al pulsar el segmento "Agenda": cambia el registro por el formulario de
  // agenda (reemplaza esta pantalla para que no se apilen).
  void _openAgenda() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => AgendaInputScreen(profile: widget.profile)),
    );
  }

  Future<void> _save() async {
    final l = context.l10n;
    final amount = double.tryParse(_amount.text.replaceAll(',', '.'));
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l.t('ti_invalid_amount'))));
      return;
    }
    // Con varios coches, nunca se guarda sin coche.
    if (_canPickVehicle && _vehiclesLoaded && _vehicles.length > 1 && _vehicleId == null) {
      // Campo en rojo + baja hasta él + mensaje: que se vea POR QUÉ no guarda.
      setState(() => _vehicleMissing = true);
      final ctx = _vehicleFieldKey.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.3);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l.t('ti_vehicle_required'))));
      return;
    }
    final km = _km.text.trim().isEmpty ? null : int.tryParse(_km.text.trim());
    final kmErr = _kmError(l);
    if (kmErr != null) {
      setState(() {}); // pinta el campo en rojo
      // Si el "último km" es un número mal apuntado, desde aquí se corrige.
      final tooLow = km != null && _lastKm != null && km < _lastKm!;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(kmErr),
        action: tooLow
            ? SnackBarAction(label: l.t('km_fix_title'), onPressed: _openKmFix)
            : null,
      ));
      return;
    }
    // Aviso de salto grande de km (solo carreras, con último km conocido).
    if (_isTrip && km != null && _lastKm != null && (km - _lastKm!) > kmJumpWarn) {
      final ok = await confirmKmJump(context, km);
      if (!ok) return;
    }
    // Registro de jornada (mig. 093): si la empresa lo exige, una CARRERA nueva
    // solo se puede apuntar con la jornada iniciada (y no en pausa).
    if (_isTrip && widget.editId == null) {
      final block = await _workdayBlock(l);
      if (block != null) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(block)));
        return;
      }
    }
    setState(() => _saving = true);
    final desc = _description.text.trim().isEmpty ? null : _description.text.trim();
    // En carrera: metadatos de viaje. En gasto: categoría.
    final origin = _isTrip && _origin.text.trim().isNotEmpty ? _origin.text.trim() : null;
    final destination =
        _isTrip && _destination.text.trim().isNotEmpty ? _destination.text.trim() : null;
    final client = _isTrip && _client.text.trim().isNotEmpty ? _client.text.trim() : null;
    final odometer = _isTrip ? km : null;
    final category = _isTrip ? null : _category;
    try {
      if (widget.editId != null) {
        await DataService().updateTransaction(
          widget.editId!,
          amount: amount,
          category: category,
          type: _type,
          paymentMethod: _payment,
          description: desc,
          origin: origin,
          destination: destination,
          odometerKm: odometer,
          clientName: client,
          createdAt: _when,
          utcOffsetMin: _utcOffsetMin,
          vehicleId: _vehicleId,
          setVehicle: _canPickVehicle && _vehiclesLoaded && _vehicles.isNotEmpty,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.t('ti_updated'))));
        Navigator.of(context).pop(true); // devuelve true: hubo cambios
        return;
      }
      await DataService().addTransaction(
        tenantId: widget.profile.tenantId,
        userId: widget.profile.id,
        amount: amount,
        category: category,
        type: _type,
        paymentMethod: _payment,
        description: desc,
        origin: origin,
        destination: destination,
        odometerKm: odometer,
        clientName: client,
        createdAt: _when,
        vehicleId: _vehicleId,
        // isPreview = el formulario viene de un parseo de VOZ; si no, es manual.
        source: widget.isPreview ? 'voice' : 'manual',
      );
      // Feedback del parseo por voz: qué se guardó al final (sin esperar).
      final fid = widget.initial?['_feedback_id'];
      if (fid is String) {
        unawaited(DataService().sendParseFeedback(fid, {
          'type': _type,
          'amount': amount,
          'payment_method': _payment,
          'category': category,
          'origin': origin,
          'destination': destination,
          'client_name': client,
          'odometer_km': odometer,
        }));
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_isTrip ? l.t('ti_trip_saved') : l.t('ti_expense_saved'))),
      );
      if (widget.popWithResult) {
        Navigator.of(context).pop(true); // vuelve a la agenda (registrar carrera)
      } else {
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendlyError(e))));
    }
  }

  // Mapea el rechazo de RLS por suscripción inactiva a un mensaje claro.
  String _friendlyError(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('row-level security') || s.contains('row level security') ||
        s.contains('policy') || s.contains('42501')) {
      return context.l10n.t('ti_blocked');
    }
    return '${context.l10n.t('error')}: $e';
  }

  void _openVoice() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => VoiceInputScreen(profile: widget.profile)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final form = ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // Carrera (ingreso) vs Gasto
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'income', label: Text(l.t('ti_trip')), icon: const Icon(Icons.local_taxi)),
            ButtonSegment(value: 'expense', label: Text(l.t('ti_expense')), icon: const Icon(Icons.receipt)),
            // Agenda (oculta y de pago): navega a su propio formulario.
            if (_agendaEnabled)
              ButtonSegment(value: 'agenda', label: Text(l.t('ti_agenda')), icon: const Icon(Icons.event_note)),
          ],
          selected: {_type},
          onSelectionChanged: (s) {
            if (s.first == 'agenda') { _openAgenda(); return; }
            setState(() => _type = s.first);
          },
        ),
        const SizedBox(height: 20),
        // Importe / precio
        TextField(
          key: const Key('amount_field'),
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
          decoration: InputDecoration(
            prefixText: '€ ',
            hintText: '0',
            labelText: _isTrip ? l.t('ti_price') : l.t('ti_amount'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        // Fecha y hora (por defecto, ahora; editable).
        OutlinedButton.icon(
          key: const Key('when_field'),
          onPressed: _pickWhen,
          icon: const Icon(Icons.event),
          style: OutlinedButton.styleFrom(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
          label: Text('${l.t('ti_datetime')}: ${fmtDateTime(_when)}'),
        ),
        ..._vehicleSelector(l),
        const SizedBox(height: 20),
        if (_isTrip) ..._tripFields(l) else ..._expenseFields(l),
        const SizedBox(height: 20),
        Text(l.t('ti_payment')),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8, runSpacing: 8,
          children: [
            _payChip('efectivo', l.t('ti_cash'), Icons.payments),
            _payChip('tarjeta', l.t('ti_card'), Icons.credit_card),
            _payChip('bizum', l.t('ti_bizum'), Icons.smartphone),
            _payChip('credito', l.t('ti_credit'), Icons.schedule),
          ],
        ),
        const SizedBox(height: 20),
        // En un gasto "Otros" la descripción ya se pide arriba como "¿Qué gasto?".
        if (_isTrip || _category != 'otros')
          TextField(
            controller: _description,
            decoration: InputDecoration(
              labelText: l.t('ti_desc'),
              border: const OutlineInputBorder(),
            ),
          ),
        const SizedBox(height: 28),
        FilledButton(
          key: const Key('save_transaction_button'),
          onPressed: _saving ? null : _save,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: _saving
                ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(
                    widget.editId != null
                        ? l.t('ti_save_changes')
                        : widget.isPreview
                            ? l.t('ti_confirm_save')
                            : l.t('ti_save'),
                    style: const TextStyle(fontSize: 18)),
          ),
        ),
      ],
    );

    if (widget.embedded) return form;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.editId != null
            ? l.t('ti_edit')
            : widget.isPreview
                ? l.t('ti_review')
                : l.t('ti_new')),
        actions: [
          if (!widget.isPreview)
            IconButton(
              key: const Key('mic_button'),
              tooltip: l.t('ti_dictate'),
              icon: const Icon(Icons.mic),
              onPressed: _openVoice,
            ),
        ],
      ),
      body: form,
    );
  }

  // Selector de vehículo (solo conductor): auto si tiene 1, desplegable si varios.
  List<Widget> _vehicleSelector(AppLocalizations l) {
    if (!_canPickVehicle || !_vehiclesLoaded || _vehicles.isEmpty) {
      return const [];
    }
    if (_vehicles.length == 1) {
      return [
        const SizedBox(height: 12),
        InputDecorator(
          decoration: InputDecoration(
            labelText: l.t('ti_vehicle'),
            prefixIcon: const Icon(Icons.directions_car),
            border: const OutlineInputBorder(),
          ),
          child: Text(_vehicleLabel(_vehicles.first)),
        ),
      ];
    }
    return [
      SizedBox(key: _vehicleFieldKey, height: 12),
      DropdownButtonFormField<String>(
        // La clave cambia con el coche: si se elige en el aviso del día, se repinta.
        key: ValueKey('vehicle_dropdown_$_vehicleId'),
        initialValue: _vehicleId,
        isExpanded: true,
        hint: Text(l.t('ti_vehicle_pick')),
        decoration: InputDecoration(
          labelText: l.t('ti_vehicle'),
          prefixIcon: const Icon(Icons.directions_car),
          border: const OutlineInputBorder(),
          errorText: _vehicleMissing && _vehicleId == null ? l.t('ti_vehicle_required') : null,
        ),
        items: [
          for (final v in _vehicles)
            DropdownMenuItem(value: v['id'] as String, child: Text(_vehicleLabel(v))),
        ],
        onChanged: (val) {
          setState(() { _vehicleId = val; _vehicleMissing = false; });
          // Cambia de coche a media jornada: pasa a ser el coche del día.
          if (val != null && widget.editId == null) setDayVehicle(widget.profile.id, val);
          _loadLastKm();
        },
      ),
    ];
  }

  // Chip de selección de forma de pago.
  Widget _payChip(String value, String label, IconData icon) => ChoiceChip(
        selected: _payment == value,
        onSelected: (_) => setState(() => _payment = value),
        avatar: Icon(icon, size: 18,
            color: _payment == value ? Colors.white : Colors.blueGrey),
        label: Text(label),
        labelStyle: TextStyle(color: _payment == value ? Colors.white : null),
        selectedColor: Theme.of(context).colorScheme.primary,
      );

  // Campos específicos de una carrera (ingreso).
  List<Widget> _tripFields(AppLocalizations l) => [
        TextField(
          key: const Key('origin_field'),
          controller: _origin,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: l.t('ti_origin'),
            prefixIcon: const Icon(Icons.my_location),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('destination_field'),
          controller: _destination,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: l.t('ti_destination'),
            prefixIcon: const Icon(Icons.location_on),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('km_field'),
          controller: _km,
          keyboardType: TextInputType.number,
          onChanged: (_) => setState(() {}), // refresca el error en vivo
          decoration: InputDecoration(
            labelText: l.t('ti_km'),
            prefixIcon: const Icon(Icons.speed),
            border: const OutlineInputBorder(),
            errorText: _kmError(l),
            helperText: _lastKm != null ? l.t('ti_km_last', {'last': _lastKm.toString()}) : null,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('client_field'),
          controller: _client,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: l.t('ti_client'),
            helperText: l.t('ti_client_help'),
            prefixIcon: const Icon(Icons.business),
            border: const OutlineInputBorder(),
          ),
        ),
      ];

  // Campos específicos de un gasto.
  List<Widget> _expenseFields(AppLocalizations l) => [
        Text(l.t('ti_category')),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: kCategories.entries
              .where((e) => e.key != 'ingreso_tarjeta')
              .map((e) {
            return ChoiceChip(
              label: Text(l.catLabel(e.key)),
              selected: _category == e.key,
              onSelected: (_) => setState(() => _category = e.key),
            );
          }).toList(),
        ),
        // "Otros": campo libre para nombrar el gasto (p. ej. ITV, ITV taxímetro).
        // Reutiliza el controlador de descripción; el campo genérico se oculta.
        if (_category == 'otros') ...[
          const SizedBox(height: 16),
          TextField(
            key: const Key('other_expense_field'),
            controller: _description,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: l.t('ti_other_what'),
              hintText: l.t('ti_other_hint'),
              prefixIcon: const Icon(Icons.edit_note),
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ];
}
