import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';

/// Alta/edición de un servicio de la AGENDA (opción oculta y de pago, Fase 1).
/// Mismos aires que el registro de carrera, pero guarda en `agenda_events`:
/// precio pactado/aprox., fecha y hora, cliente/empresa, recogida, destino,
/// teléfono o nombre de contacto y una nota opcional.
class AgendaInputScreen extends StatefulWidget {
  final Profile profile;
  final String? editId; // si != null, edita el servicio existente
  final Map<String, dynamic>? initial; // prefill (edición o parseo de voz)
  const AgendaInputScreen({super.key, required this.profile, this.editId, this.initial});

  @override
  State<AgendaInputScreen> createState() => _AgendaInputScreenState();
}

class _AgendaInputScreenState extends State<AgendaInputScreen> {
  final _service = DataService();
  final _price = TextEditingController();
  final _name = TextEditingController();
  final _pickup = TextEditingController();
  final _dest = TextEditingController();
  final _contact = TextEditingController();
  final _note = TextEditingController();
  late DateTime _when;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _when = DateTime.now();
    final i = widget.initial;
    if (i != null) {
      if (i['price_approx'] != null) _price.text = '${i['price_approx']}';
      if (i['name'] != null) _name.text = '${i['name']}';
      if (i['pickup'] != null) _pickup.text = '${i['pickup']}';
      if (i['destination'] != null) _dest.text = '${i['destination']}';
      if (i['contact'] != null) _contact.text = '${i['contact']}';
      if (i['note'] != null) _note.text = '${i['note']}';
      if (i['scheduled_at'] != null) {
        _when = DateTime.tryParse('${i['scheduled_at']}')?.toLocal() ?? _when;
      }
    }
  }

  @override
  void dispose() {
    _price.dispose();
    _name.dispose();
    _pickup.dispose();
    _dest.dispose();
    _contact.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _when,
      firstDate: DateTime(2020),
      lastDate: DateTime(DateTime.now().year + 2, 12, 31),
    );
    if (d != null) {
      setState(() => _when = DateTime(d.year, d.month, d.day, _when.hour, _when.minute));
    }
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_when));
    if (t != null) {
      setState(() => _when = DateTime(_when.year, _when.month, _when.day, t.hour, t.minute));
    }
  }

  Future<void> _save() async {
    final l = context.l10n;
    // Mínimo: recogida o destino o nombre (que haya algo que apuntar).
    if (_pickup.text.trim().isEmpty && _dest.text.trim().isEmpty && _name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('ag_need_something'))));
      return;
    }
    setState(() => _saving = true);
    final price = _price.text.trim().isEmpty
        ? null
        : double.tryParse(_price.text.trim().replaceAll(',', '.'));
    String? nn(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    try {
      if (widget.editId != null) {
        await _service.updateAgendaEvent(widget.editId!, {
          'scheduled_at': _when.toUtc().toIso8601String(),
          'name': nn(_name),
          'pickup': nn(_pickup),
          'destination': nn(_dest),
          'contact': nn(_contact),
          'price_approx': price,
          'note': nn(_note),
        });
      } else {
        await _service.addAgendaEvent(
          tenantId: widget.profile.tenantId,
          userId: widget.profile.id,
          scheduledAt: _when,
          name: nn(_name),
          pickup: nn(_pickup),
          destination: nn(_dest),
          contact: nn(_contact),
          priceApprox: price,
          note: nn(_note),
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('ag_saved'))));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l.t('error')}: $e')));
    }
  }

  String _fmtWhen() {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(_when.day)}/${two(_when.month)}/${_when.year} · ${two(_when.hour)}:${two(_when.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.editId == null ? l.t('ag_new_title') : l.t('ag_edit_title')),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: _price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: l.t('ag_price'),
                  prefixIcon: const Icon(Icons.euro),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.event, size: 18),
                label: Text('${_when.day.toString().padLeft(2, '0')}/${_when.month.toString().padLeft(2, '0')}'),
              ),
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: _pickTime,
              icon: const Icon(Icons.schedule, size: 18),
              label: Text('${_when.hour.toString().padLeft(2, '0')}:${_when.minute.toString().padLeft(2, '0')}'),
            ),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: l.t('ag_name'),
              prefixIcon: const Icon(Icons.person),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pickup,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: l.t('ag_pickup'),
              prefixIcon: const Icon(Icons.my_location),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _dest,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: l.t('ag_dest'),
              prefixIcon: const Icon(Icons.flag),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _contact,
            decoration: InputDecoration(
              labelText: l.t('ag_contact'),
              prefixIcon: const Icon(Icons.phone),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            textCapitalization: TextCapitalization.sentences,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: l.t('ag_note'),
              prefixIcon: const Icon(Icons.notes),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text('${l.t('ag_when')}: ${_fmtWhen()}',
              style: TextStyle(color: Theme.of(context).colorScheme.outline, fontSize: 12)),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.calendar_month),
            label: Text(l.t('ag_save')),
          ),
        ],
      ),
    );
  }
}
