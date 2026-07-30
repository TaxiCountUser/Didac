import 'package:flutter/material.dart';

/// Ámbar del segmento "Count" del logotipo (algo más profundo que el del
/// isotipo, para que contraste sobre fondo claro).
const brandAmber = Color(0xFFFFB300);

/// El nombre con el corte de color de la marca registrada: "Taxi" hereda el
/// color de texto del tema (así funciona igual sobre el crema del cliente que
/// sobre el oscuro del panel de admin) y "Count" va en ámbar.
Widget brandWordmark(BuildContext context, {TextStyle? style}) {
  final base = style ?? Theme.of(context).textTheme.headlineMedium;
  return Text.rich(
    TextSpan(children: [
      TextSpan(text: 'Taxi', style: base),
      TextSpan(text: 'Count', style: (base ?? const TextStyle()).copyWith(color: brandAmber)),
    ]),
    textAlign: TextAlign.center,
  );
}
