import 'package:flutter/material.dart';

/// Ámbar del segmento "Count" del logotipo (algo más profundo que el del
/// isotipo, para que contraste sobre fondo claro).
const brandAmber = Color(0xFFFFB300);

/// El nombre con el corte de color de la marca registrada: "Taxi" hereda el
/// color de texto del tema (así funciona igual sobre el crema del cliente que
/// sobre el oscuro del panel de admin) y "Count" va en ámbar.
/// Pinta una frase que conté "TaxiCount" amb el tall de color de la marca.
/// Serveix per a textos traduïts ("Benvingut a TaxiCount"): el nom és invariable
/// en els tres idiomes, així que n'hi ha prou de partir per ell.
Widget brandInText(BuildContext context, String text, {TextStyle? style}) {
  const brand = 'TaxiCount';
  final base = style ?? Theme.of(context).textTheme.headlineSmall;
  final i = text.indexOf(brand);
  if (i < 0) return Text(text, style: base, textAlign: TextAlign.center);
  final amber = (base ?? const TextStyle()).copyWith(color: brandAmber);
  return Text.rich(
    TextSpan(children: [
      TextSpan(text: text.substring(0, i), style: base),
      TextSpan(text: 'Taxi', style: base),
      TextSpan(text: 'Count', style: amber),
      TextSpan(text: text.substring(i + brand.length), style: base),
    ]),
    textAlign: TextAlign.center,
  );
}

/// El mateix logotip per a la barra superior, agafant l'estil de títol del tema
/// (si no, hereta headlineMedium i surt desproporcionat dins l'AppBar).
Widget brandAppBarTitle(BuildContext context) {
  final t = Theme.of(context);
  return brandWordmark(context, style: t.appBarTheme.titleTextStyle ?? t.textTheme.titleLarge);
}

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
