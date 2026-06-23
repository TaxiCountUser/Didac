import 'package:flutter/material.dart';

import '../models/profile.dart';
import 'transaction_input_screen.dart';
import 'voice_capture.dart';

/// Añadir registro: el conductor elige entre dictar por voz o rellenar a mano.
/// Si dicta, el resultado rellena el formulario manual para confirmarlo.
class AddRecordScreen extends StatefulWidget {
  final Profile profile;
  const AddRecordScreen({super.key, required this.profile});

  @override
  State<AddRecordScreen> createState() => _AddRecordScreenState();
}

class _AddRecordScreenState extends State<AddRecordScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
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
      const SnackBar(content: Text('Revisa los datos y guarda')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Añadir registro'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.edit), text: 'Manual'),
            Tab(icon: Icon(Icons.mic), text: 'Voz'),
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
          VoiceCapture(onParsed: _onParsed),
        ],
      ),
    );
  }
}
