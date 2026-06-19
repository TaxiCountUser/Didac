import 'package:flutter/material.dart';

import '../models/profile.dart';
import 'transaction_input_screen.dart';

/// Previsualización editable de una transacción parseada por voz.
/// Reutiliza el formulario de entrada en modo "preview".
class TransactionPreviewScreen extends StatelessWidget {
  final Profile profile;
  final Map<String, dynamic> parsed;
  const TransactionPreviewScreen({
    super.key,
    required this.profile,
    required this.parsed,
  });

  @override
  Widget build(BuildContext context) {
    return TransactionInputScreen(
      profile: profile,
      initial: parsed,
      isPreview: true,
    );
  }
}
