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

/// Entrada de transacción: manual o como previsualización de un parseo de voz.
class TransactionInputScreen extends StatefulWidget {
  final Profile profile;
  final Map<String, dynamic>? initial; // valores parseados (modo preview)
  final bool isPreview;
  final String? editId; // si != null, edita la transacción existente
  const TransactionInputScreen({
    super.key,
    required this.profile,
    this.initial,
    this.isPreview = false,
    this.editId,
  });

  @override
  State<TransactionInputScreen> createState() => _TransactionInputScreenState();
}

class _TransactionInputScreenState extends State<TransactionInputScreen> {
  final _amount = TextEditingController();
  final _description = TextEditingController();
  String? _category;
  String _type = 'expense';
  String _payment = 'tarjeta';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    if (i != null) {
      if (i['amount'] != null) _amount.text = (i['amount']).toString();
      _category = kCategories.containsKey(i['category']) ? i['category'] as String? : null;
      _type = (i['type'] as String?) ?? 'expense';
      _payment = (i['payment_method'] as String?) ?? 'tarjeta';
      if (i['description'] != null) _description.text = i['description'] as String;
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amount.text.replaceAll(',', '.'));
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Introduce un importe válido')));
      return;
    }
    setState(() => _saving = true);
    final desc = _description.text.trim().isEmpty ? null : _description.text.trim();
    try {
      if (widget.editId != null) {
        await DataService().updateTransaction(
          widget.editId!,
          amount: amount,
          category: _category,
          type: _type,
          paymentMethod: _payment,
          description: desc,
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
        category: _category,
        type: _type,
        paymentMethod: _payment,
        description: desc,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Transacción guardada')));
      Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  void _openVoice() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => VoiceInputScreen(profile: widget.profile)),
    );
  }

  @override
  Widget build(BuildContext context) {
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
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Importe
          TextField(
            key: const Key('amount_field'),
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
            decoration: const InputDecoration(
              prefixText: '€ ',
              hintText: '0',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          // Tipo
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'expense', label: Text('Gasto'), icon: Icon(Icons.south)),
              ButtonSegment(value: 'income', label: Text('Ingreso'), icon: Icon(Icons.north)),
            ],
            selected: {_type},
            onSelectionChanged: (s) => setState(() => _type = s.first),
          ),
          const SizedBox(height: 20),
          const Text('Categoría'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: kCategories.entries.map((e) {
              return ChoiceChip(
                label: Text(e.value),
                selected: _category == e.key,
                onSelected: (_) => setState(() => _category = e.key),
              );
            }).toList(),
          ),
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
      ),
    );
  }
}
