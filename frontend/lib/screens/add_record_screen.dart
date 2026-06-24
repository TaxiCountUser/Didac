import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
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

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _onParsed(Map<String, dynamic> parsed) {
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
