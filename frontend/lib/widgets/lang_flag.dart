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
    final emoji = switch (code) {
      'es' => '🇪🇸',
      'en' => '🇬🇧',
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
