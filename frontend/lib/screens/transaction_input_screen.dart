import 'package:flutter/material.dart';

import '../models/profile.dart';
import '../services/data_service.dart';
import 'voice_input_screen.dart';

const kCategories = <String, String>{
  'gasolina': 'Gasolina',
  'gasoil': 'Gasoil',
  'taller': 'Taller',
  'peaje': 'Peaje',
  'parking': 'Parking',
  'lavado': 'Lavado',
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
  bool _saving = false;

  @override
  void initState() {
    super.initState();
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
    }
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
    final amount = double.tryParse(_amount.text.replaceAll(',', '.'));
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Introduce un importe válido')));
      return;
    }
    final km = _km.text.trim().isEmpty ? null : int.tryParse(_km.text.trim());
    if (_isTrip && _km.text.trim().isNotEmpty && km == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Los km deben ser un número entero')));
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
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Transacción actualizada')));
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
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_isTrip ? 'Carrera guardada' : 'Gasto guardado')),
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
      return 'Operación bloqueada. Contacta con el administrador de la flota';
    }
    return 'Error: $e';
  }

  void _openVoice() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => VoiceInputScreen(profile: widget.profile)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final form = ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // Carrera (ingreso) vs Gasto
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'income', label: Text('Carrera'), icon: Icon(Icons.local_taxi)),
            ButtonSegment(value: 'expense', label: Text('Gasto'), icon: Icon(Icons.receipt)),
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
            labelText: _isTrip ? 'Precio' : 'Importe',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 20),
        if (_isTrip) ..._tripFields() else ..._expenseFields(),
        const SizedBox(height: 20),
        const Text('Método de pago'),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'tarjeta', label: Text('Tarjeta'), icon: Icon(Icons.credit_card)),
            ButtonSegment(value: 'efectivo', label: Text('Efectivo'), icon: Icon(Icons.payments)),
          ],
          selected: {_payment},
          onSelectionChanged: (s) => setState(() => _payment = s.first),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _description,
          decoration: const InputDecoration(
            labelText: 'Descripción (opcional)',
            border: OutlineInputBorder(),
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
                        ? 'Guardar cambios'
                        : widget.isPreview
                            ? 'Confirmar y guardar'
                            : 'Guardar',
                    style: const TextStyle(fontSize: 18)),
          ),
        ),
      ],
    );

    if (widget.embedded) return form;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.editId != null
            ? 'Editar transacción'
            : widget.isPreview
                ? 'Revisar transacción'
                : 'Nueva transacción'),
        actions: [
          if (!widget.isPreview)
            IconButton(
              key: const Key('mic_button'),
              tooltip: 'Dictar por voz',
              icon: const Icon(Icons.mic),
              onPressed: _openVoice,
            ),
        ],
      ),
      body: form,
    );
  }

  // Campos específicos de una carrera (ingreso).
  List<Widget> _tripFields() => [
        TextField(
          key: const Key('origin_field'),
          controller: _origin,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Origen',
            prefixIcon: Icon(Icons.my_location),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('destination_field'),
          controller: _destination,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Destino',
            prefixIcon: Icon(Icons.location_on),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('km_field'),
          controller: _km,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Km del coche (opcional)',
            prefixIcon: Icon(Icons.speed),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('client_field'),
          controller: _client,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Cliente / empresa',
            helperText: 'Vacío = cliente particular',
            prefixIcon: Icon(Icons.business),
            border: OutlineInputBorder(),
          ),
        ),
      ];

  // Campos específicos de un gasto.
  List<Widget> _expenseFields() => [
        const Text('Categoría'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: kCategories.entries
              .where((e) => e.key != 'ingreso_tarjeta')
              .map((e) {
            return ChoiceChip(
              label: Text(e.value),
              selected: _category == e.key,
              onSelected: (_) => setState(() => _category = e.key),
            );
          }).toList(),
        ),
      ];
}
