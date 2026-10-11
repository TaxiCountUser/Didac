import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taxicount/assistant/assistant_engine.dart';

void main() {
  final seed = jsonDecode(File('assets/assistant/kb.json').readAsStringSync()) as Map<String, dynamic>;
  final engine = AssistantEngine(AssistantKb.build(seed));

  // Pregunta -> respuesta esperada (frases que NO están literalmente en el JSON).
  const cases = <List<String>>[
    ['es', 'no se como cerrar el turno', 'end_shift'],
    ['es', 'como acabo la jornada de hoy', 'end_shift'],
    ['es', 'donde le doy para empezar a trabajar', 'start_shift'],
    ['es', 'el micro no me funciona', 'mic_permission'],
    ['es', 'quiero apuntar una carrera hablando', 'add_voice'],
    ['es', 'me equivoque en el importe de un viaje', 'edit_record'],
    ['es', 'cuanto cuesta la aplicacion', 'price'],
    ['es', 'como añado un chofer nuevo', 'invite_driver'],
    ['es', 'olvide mi contraseña', 'forgot_password'],
    ['es', 'quiero sacar un excel para la gestoria', 'export'],
    ['es', 'me sale que la prueba gratuita ha terminado', 'trial_ended'],
    ['es', 'como cancelo', 'cancel'],
    ['es', 'quiero hablar con una persona', 'human'],
    ['es', 'hola', 'greet'],
    ['es', 'cerar jornada', 'end_shift'], // falta de ortografía
    ['es', 'donde estan las facturas', 'invoices'],
    ['es', 'como apunto el gasoil', 'add_expense'],
    ['ca', 'com tanco el torn', 'end_shift'],
    ['ca', 'quant costa', 'price'],
    ['ca', 'he oblidat la contrasenya', 'forgot_password'],
    ['en', 'how do i finish my shift', 'end_shift'],
    ['en', 'how much is it', 'price'],
    ['es', 'hola, como cierro la jornada?', 'end_shift'],
    ['es', 'muchas gracias!', 'thanks'],
    ['es', 'eres un robot?', 'who_are_you'],
    ['es', 'necesito hablar con alguien de soporte', 'human'],
    ['es', 'mi conductor no puede entrar en la app', 'edit_driver'],
    ['es', 'como pongo la itv del coche', 'maintenance'],
    ['es', 'donde veo cuanto he ganado este mes', 'view_transactions'],
    ['es', 'me dice que los km no son correctos', 'km_too_low'],
    ['es', 'la app se queda cargando', 'offline'],
    ['es', 'como cambio la contraseña', 'change_password'],
    ['es', 'tengo un codigo de descuento', 'coupon'],
    ['es', 'quiero borrar mi cuenta', 'delete_account'],
    ['es', 'como me uno a la flota de mi jefe', 'join_fleet'],
    ['es', 'no me llegan las notificaciones', 'notifications'],
    ['es', 'kiero cambiar el idioma', 'language'],
  ];

  for (final c in cases) {
    test('${c[0]}: "${c[1]}" -> ${c[2]}', () {
      final r = engine.search(c[1], lang: c[0], role: 'owner');
      expect(r, isNotEmpty);
      expect(r.first.entry.id, c[2], reason: r.take(3).map((m) => '${m.entry.id}:${m.score.toStringAsFixed(2)}').join(' '));
      expect(r.first.score, greaterThanOrEqualTo(0.45), reason: 'score ${r.first.score}');
    });
  }

  test('pregunta sin relación -> nada seguro', () {
    final r = engine.search('receta de paella valenciana', lang: 'es');
    expect(r.isEmpty || r.first.score < 0.45, isTrue, reason: r.isEmpty ? '' : '${r.first.entry.id} ${r.first.score}');
  });

  test('frase aprendida -> coincidencia exacta', () {
    final kb = AssistantKb.build(seed, {
      'entries': [],
      'learned': [{'phrase': 'el boton rojo no hace nada', 'entry_id': 'end_shift'}],
    });
    final r = AssistantEngine(kb).search('El botón rojo no hace nada', lang: 'es');
    expect(r.first.entry.id, 'end_shift');
    expect(r.first.score, 1.0);
  });
}
