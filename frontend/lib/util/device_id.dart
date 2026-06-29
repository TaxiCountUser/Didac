import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Identificador de dispositivo persistente (anónimo) para el anti-fraude de
/// referidos. No es un dato sensible: es un id aleatorio que se guarda en el
/// propio dispositivo y se reutiliza. Sirve para detectar varios registros
/// desde el mismo móvil.
Future<String> getDeviceId() async {
  final prefs = await SharedPreferences.getInstance();
  var id = prefs.getString('device_id');
  if (id == null || id.isEmpty) {
    final r = Random.secure();
    id = List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
    await prefs.setString('device_id', id);
  }
  return id;
}
