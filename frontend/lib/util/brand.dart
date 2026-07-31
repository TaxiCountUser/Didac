import 'package:flutter/material.dart';

/// Ámbar de la marca. Es **el mismo** que el de la carrocería del isotipo: el
/// símbolo y la palabra van siempre del mismo color.
const brandAmber = Color(0xFFFFC107);

/// El logotipo de verdad, como imagen: el nombre compuesto en Lora con la
/// ligadura CT haciendo de C. Se usa donde la marca se muestra como marca
/// (portadas), no donde el nombre es texto corrido.
///
/// Elige la versión clara u oscura según el tema, porque "Taxi" va en negro
/// cálido y sobre el fondo oscuro del panel de admin desaparecería.
Widget brandLogotipo(BuildContext context, {double height = 40}) {
  final oscuro = Theme.of(context).brightness == Brightness.dark;
  return Image.asset(
    oscuro ? 'assets/brand/logotipo-oscuro.png' : 'assets/brand/logotipo.png',
    height: height,
  );
}

/// Pinta una frase que contiene "TaxiCount" con el corte de color de la marca.
/// Sirve para textos traducidos ("Bienvenido a TaxiCount"): el nombre es
/// invariable en los tres idiomas, así que basta con partir por él.
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

/// El nombre para la barra superior, con el estilo de título del tema (si no,
/// hereda headlineMedium y sale desproporcionado dentro del AppBar).
Widget brandAppBarTitle(BuildContext context) {
  final t = Theme.of(context);
  return brandWordmark(context, style: t.appBarTheme.titleTextStyle ?? t.textTheme.titleLarge);
}

/// El nombre como texto, con el corte de color. Para barras y rótulos, donde
/// una imagen no encajaría con el resto de la tipografía de la interfaz.
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
