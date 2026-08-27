import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import 'agenda_input_screen.dart';
import 'transaction_input_screen.dart';
import 'voice_capture.dart';

/// Añadir registro: el conductor elige entre dictar por voz o rellenar a mano.
/// Si dicta, el resultado rellena el formulario manual para confirmarlo.
class AddRecordScreen extends StatefulWidget {
  final Profile profile;
  final bool startOnVoice; // atajo: abrir directamente en la pestaña de voz
  const AddRecordScreen({super.key, required this.profile, this.startOnVoice = false});

  @override
  State<AddRecordScreen> createState() => _AddRecordScreenState();
}

class _AddRecordScreenState extends State<AddRecordScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs =
      TabController(length: 2, vsync: this, initialIndex: widget.startOnVoice ? 1 : 0);
  Map<String, dynamic>? _initial; // valores precargados por la voz
  int _formSeq = 0; // fuerza re-init del formulario al llegar datos de voz
  bool _agendaEnabled = false; // opción Agenda (oculta): habilita el disparador de voz

  @override
  void initState() {
    super.initState();
    _loadAgendaFlag();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadAgendaFlag() async {
    final on = await DataService().isAgendaEnabled(widget.profile.tenantId);
    if (mounted && on) setState(() => _agendaEnabled = true);
  }

  // Disparador de voz para la agenda: "apunta en la agenda" (es) / "apunta a
  // l'agenda" (ca) / "add to agenda" (en). Best-effort sobre el texto crudo.
  bool _isAgendaTrigger(String lower) =>
      lower.contains('apunta en la agenda') ||
      lower.contains("apunta a l'agenda") ||
      lower.contains('apunta a la agenda') ||
      lower.contains('add to agenda') ||
      lower.contains('add to the agenda');

  // Extrae un precio del texto: número seguido de € / euro(s) / pavos. Coge el
  // ÚLTIMO (el precio suele ir al final de la frase). Así no confunde la hora
  // ("a las 3") con el precio ("65 euros").
  double? _priceFromText(String raw) {
    final re = RegExp(r'(\d+(?:[.,]\d+)?)\s*(?:€|euros?|pavos?)', caseSensitive: false);
    double? last;
    for (final m in re.allMatches(raw)) {
      last = double.tryParse(m.group(1)!.replaceAll(',', '.'));
    }
    return last;
  }

  void _onParsed(Map<String, dynamic> parsed) {
    final raw = (parsed['description'] as String?) ?? '';
    // Parseo dedicado de agenda hecho en el backend (LLM), si lo hubo.
    final agRaw = parsed['_agenda'];
    final Map<String, dynamic>? ag =
        agRaw is Map ? Map<String, dynamic>.from(agRaw) : null;
    // Es un dictado de agenda si el backend lo parseó como tal o si detectamos la
    // muletilla (respaldo por si el LLM no estaba disponible).
    if (_agendaEnabled && (ag != null || _isAgendaTrigger(raw.toLowerCase()))) {
      // Preferimos los campos del LLM de agenda; si falta alguno, respaldo con la
      // heurística: fecha/hora dicha (created_at) y precio junto a €/euros (no la
      // hora). El texto entero queda en la nota por si algo no se cogió.
      final initial = <String, dynamic>{
        'scheduled_at': (ag?['when'] as String?) ?? parsed['created_at'],
        'name': ag?['name'] ?? parsed['client_name'],
        'pickup': ag?['pickup'] ?? parsed['origin'],
        'destination': ag?['destination'] ?? parsed['destination'],
        'contact': ag?['phone'],
        'price_approx': ag?['price'] ?? _priceFromText(raw),
        'note': raw,
      };
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AgendaInputScreen(profile: widget.profile, initial: initial),
      ));
      return;
    }
    setState(() {
      _initial = parsed;
      _formSeq++;
    });
    _tabs.animateTo(0); // ir a "Manual" para revisar/confirmar
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.t('ar_review'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.t('ar_title')),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(icon: const Icon(Icons.edit), text: l.t('ar_manual')),
            Tab(icon: const Icon(Icons.mic), text: l.t('ar_voice')),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          TransactionInputScreen(
            key: ValueKey('form_$_formSeq'),
            profile: widget.profile,
            initial: _initial,
            isPreview: _initial != null,
            embedded: true,
          ),
          VoiceCapture(onParsed: _onParsed, autoStart: widget.startOnVoice),
        ],
      ),
    );
  }
}
