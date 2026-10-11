import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Etiqueta de día para la agenda: Hoy / Mañana para fechas próximas; si no, la
/// fecha (dd/mm/aaaa). Reutilizada por la agenda y por su histórico.
String agendaDayLabel(BuildContext context, DateTime? d) {
  if (d == null) return '';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = day.difference(today).inDays;
  final l = context.l10n;
  if (diff == 0) return l.t('ag_today');
  if (diff == 1) return l.t('ag_tomorrow');
  return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

/// Construye el mapa de prellenado para registrar un servicio de la agenda como
/// carrera (lo consume `TransactionInputScreen.initial`).
Map<String, dynamic> agendaToTripInitial(Map<String, dynamic> ev) {
  String? s(String k) {
    final v = (ev[k] as String?)?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  return <String, dynamic>{
    'type': 'income',
    if (ev['price_approx'] != null) 'amount': ev['price_approx'],
    if (s('pickup') != null) 'origin': s('pickup'),
    if (s('destination') != null) 'destination': s('destination'),
    if (s('name') != null) 'client_name': s('name'),
    if (s('note') != null) 'description': s('note'),
    if (ev['scheduled_at'] != null) 'created_at': ev['scheduled_at'],
  };
}

/// Construye una lista con cabeceras de día a partir de eventos YA ordenados.
/// [tile] pinta cada fila (normalmente un [AgendaTile]).
List<Widget> buildAgendaGrouped(
  BuildContext context,
  List<Map<String, dynamic>> items, {
  required Widget Function(Map<String, dynamic> ev, DateTime? when) tile,
}) {
  final out = <Widget>[];
  String? lastDay;
  for (final ev in items) {
    final when = DateTime.tryParse('${ev['scheduled_at']}')?.toLocal();
    final dayKey = when == null ? '' : '${when.year}-${when.month}-${when.day}';
    if (dayKey != lastDay) {
      lastDay = dayKey;
      out.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        child: Text(agendaDayLabel(context, when),
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      ));
    }
    out.add(tile(ev, when));
  }
  out.add(const SizedBox(height: 80));
  return out;
}

/// Fila de un servicio de la agenda (hora, nombre, ruta, contacto, precio) con
/// acciones de marcar hecho / editar / borrar. Reutilizada por agenda e histórico.
class AgendaTile extends StatelessWidget {
  final Map<String, dynamic> ev;
  final DateTime? when;
  final VoidCallback onToggleDone;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onRegister; // registrar el servicio como carrera
  const AgendaTile({
    super.key,
    required this.ev,
    required this.when,
    required this.onToggleDone,
    required this.onEdit,
    required this.onDelete,
    required this.onRegister,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final w = when;
    final done = ev['status'] == 'done';
    final hhmm = w == null
        ? '--:--'
        : '${w.hour.toString().padLeft(2, '0')}:${w.minute.toString().padLeft(2, '0')}';
    final name = (ev['name'] as String?)?.trim() ?? '';
    final pickup = (ev['pickup'] as String?)?.trim() ?? '';
    final dest = (ev['destination'] as String?)?.trim() ?? '';
    final contact = (ev['contact'] as String?)?.trim() ?? '';
    final note = (ev['note'] as String?)?.trim() ?? '';
    final price = ev['price_approx'];
    final author =
        (ev['users'] as Map?)?['name'] ?? (ev['users'] as Map?)?['email'] ?? '';
    final route = (pickup.isNotEmpty || dest.isNotEmpty)
        ? '${pickup.isEmpty ? '—' : pickup} → ${dest.isEmpty ? '—' : dest}'
        : '';
    final sub = <String>[
      if (contact.isNotEmpty) '📞 $contact',
      if (author.toString().isNotEmpty) '${l.t('ag_by')}: $author',
      if (note.isNotEmpty) note,
    ].join(' · ');

    return ListTile(
      leading: IconButton(
        tooltip: done ? l.t('ag_mark_pending') : l.t('ag_mark_done'),
        icon: Icon(done ? Icons.check_circle : Icons.radio_button_unchecked,
            color: done ? Colors.green : null),
        onPressed: onToggleDone,
      ),
      title: Text(
        [hhmm, if (name.isNotEmpty) name, if (route.isNotEmpty) route].join(' · '),
        style: TextStyle(
          decoration: done ? TextDecoration.lineThrough : null,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: sub.isEmpty ? null : Text(sub, style: const TextStyle(fontSize: 12)),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (price != null)
          Text('${(price as num).toStringAsFixed(2)} €',
              style: const TextStyle(fontWeight: FontWeight.w600)),
        PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'register') onRegister();
            if (v == 'edit') onEdit();
            if (v == 'delete') onDelete();
          },
          itemBuilder: (ctx) => [
            PopupMenuItem(
              value: 'register',
              child: Row(children: [
                const Icon(Icons.add_task, size: 18),
                const SizedBox(width: 8),
                Text(l.t('ag_register_trip')),
              ]),
            ),
            PopupMenuItem(value: 'edit', child: Text(l.t('edit'))),
            PopupMenuItem(value: 'delete', child: Text(l.t('ag_delete'))),
          ],
        ),
      ]),
      onTap: onEdit,
    );
  }
}
