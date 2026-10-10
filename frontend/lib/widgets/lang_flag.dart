import 'package:flutter/material.dart';

/// Bandera del idioma. Para catalán dibuja la Senyera oficial (4 franjas rojas
/// sobre fondo dorado = 9 franjas); para el resto usa el emoji de bandera.
class LangFlag extends StatelessWidget {
  final String code;
  final double size; // alto en píxeles
  const LangFlag(this.code, {super.key, this.size = 24});

  @override
  Widget build(BuildContext context) {
    if (code == 'ca') {
      return ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: CustomPaint(
          size: Size(size * 1.5, size), // proporción 3:2
          painter: _SenyeraPainter(),
        ),
      );
    }
    if (code == 'eu') {
      // Euskara no tiene emoji de bandera: pintamos la ikurriña.
      return ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: CustomPaint(
          size: Size(size * 1.5, size), // proporción 3:2
          painter: _IkurrinaPainter(),
        ),
      );
    }
    final emoji = switch (code) {
      'es' => '🇪🇸',
      'en' => '🇬🇧',
      'fr' => '🇫🇷',
      'it' => '🇮🇹',
      'de' => '🇩🇪',
      'pt' => '🇵🇹',
      _ => '🏳️',
    };
    return Text(emoji, style: TextStyle(fontSize: size));
  }
}

/// Pinta la Senyera: 9 franjas horizontales iguales, dorado y rojo alternados,
/// empezando y acabando en dorado (5 doradas + 4 rojas).
class _SenyeraPainter extends CustomPainter {
  static const _gold = Color(0xFFFCDD09);
  static const _red = Color(0xFFDA121A);

  @override
  void paint(Canvas canvas, Size size) {
    final stripe = size.height / 9.0;
    canvas.drawRect(Offset.zero & size, Paint()..color = _gold);
    final redPaint = Paint()..color = _red;
    // Franjas rojas en las posiciones 1, 3, 5, 7 (0-indexado).
    for (final i in [1, 3, 5, 7]) {
      canvas.drawRect(
        Rect.fromLTWH(0, stripe * i, size.width, stripe),
        redPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Pinta la ikurriña: fondo rojo, aspa (sotuer) verde en diagonal y, encima,
/// la cruz blanca recta centrada.
class _IkurrinaPainter extends CustomPainter {
  static const _red = Color(0xFFD52B1E);
  static const _green = Color(0xFF009B48);
  static const _white = Color(0xFFFFFFFF);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // Fondo rojo.
    canvas.drawRect(Offset.zero & size, Paint()..color = _red);
    // Aspa verde (esquina a esquina).
    final green = Paint()
      ..color = _green
      ..strokeWidth = h * 0.18
      ..strokeCap = StrokeCap.butt;
    canvas.drawLine(Offset.zero, Offset(w, h), green);
    canvas.drawLine(Offset(w, 0), Offset(0, h), green);
    // Cruz blanca recta encima.
    final white = Paint()..color = _white;
    final arm = h * 0.18;
    canvas.drawRect(Rect.fromLTWH((w - arm) / 2, 0, arm, h), white); // vertical
    canvas.drawRect(Rect.fromLTWH(0, (h - arm) / 2, w, arm), white); // horizontal
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
