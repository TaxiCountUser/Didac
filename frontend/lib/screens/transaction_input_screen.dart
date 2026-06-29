import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import '../util/format.dart';
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
  const TransactionInputScreen({
    super.key,
    required this.profile,
    this.initial,
    this.isPreview = false,
    this.editId,
    this.embedded = false,
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
  bool _saving = false;

  // Vehículos asignados al conductor (para imputar el coche).
  List<Map<String, dynamic>> _vehicles = const [];
  String? _vehicleId;
  bool _vehiclesLoaded = false;
  // Último km registrado del vehículo seleccionado (para validar que no baje).
  int? _lastKm;

  @override
  void initState() {
    super.initState();
    _when = DateTime.now();
    if (!widget.profile.isOwner) _loadVehicles();
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
      if (i['created_at'] != null) _when = parseCreatedAt(i['created_at']).toLocal();
    }
  }

  Future<void> _loadVehicles() async {
    try {
      final vs = await DataService().myVehicles();
      // Vehículo "activo" del día (el que eligió al empezar la jornada).
      String? todays;
      if (widget.editId == null) {
        todays = await DataService().todaysVehicleId(widget.profile.id);
      }
      if (!mounted) return;
      setState(() {
        _vehicles = vs;
        _vehiclesLoaded = true;
        final initVid = widget.initial?['vehicle_id'] as String?;
        if (initVid != null && vs.any((v) => v['id'] == initVid)) {
          _vehicleId = initVid;
        } else if (todays != null && vs.any((v) => v['id'] == todays)) {
          _vehicleId = todays; // preselecciona el coche del día
        } else if (vs.length == 1) {
          _vehicleId = vs.first['id'] as String?;
        }
      });
      _loadLastKm();
    } catch (_) {
      if (mounted) setState(() => _vehiclesLoaded = true);
    }
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
      final k = await DataService().lastOdometer(vid);
      if (mounted) setState(() => _lastKm = k);
    } catch (_) {
      // Sin conexión: no bloqueamos por no poder comprobar.
    }
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

  Future<void> _save() async {
    final l = context.l10n;
    final amount = double.tryParse(_amount.text.replaceAll(',', '.'));
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l.t('ti_invalid_amount'))));
      return;
    }
    final km = _km.text.trim().isEmpty ? null : int.tryParse(_km.text.trim());
    final kmErr = _kmError(l);
    if (kmErr != null) {
      setState(() {}); // pinta el campo en rojo
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(kmErr)));
      return;
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
          vehicleId: _vehicleId,
          setVehicle: !widget.profile.isOwner,
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
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_isTrip ? l.t('ti_trip_saved') : l.t('ti_expense_saved'))),
      );
      Navigator.of(context).popUntil((r) => r.isFirst);
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
          ],
          selected: {_type},
          onSelectionChanged: (s) => setState(() => _type = s.first),
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
    if (widget.profile.isOwner || !_vehiclesLoaded || _vehicles.isEmpty) {
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
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        key: const Key('vehicle_dropdown'),
        initialValue: _vehicleId,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: l.t('ti_vehicle'),
          prefixIcon: const Icon(Icons.directions_car),
          border: const OutlineInputBorder(),
        ),
        items: [
          for (final v in _vehicles)
            DropdownMenuItem(value: v['id'] as String, child: Text(_vehicleLabel(v))),
        ],
        onChanged: (val) {
          setState(() => _vehicleId = val);
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
      ];
}
