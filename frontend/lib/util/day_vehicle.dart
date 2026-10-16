import 'package:shared_preferences/shared_preferences.dart';

/// Coche con el que el usuario trabaja HOY cuando no ha iniciado el día: lo elige
/// una vez (en la primera carrera) y vale hasta medianoche, en este móvil. Si
/// cambia de coche en una carrera, pasa a ser el nuevo coche del día.
String _today() {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

Future<String?> getDayVehicle(String userId) async {
  try {
    final v = (await SharedPreferences.getInstance()).getString('day_vehicle_$userId');
    if (v == null) return null;
    final parts = v.split('|');
    return parts.length == 2 && parts[0] == _today() ? parts[1] : null;
  } catch (_) {
    return null;
  }
}

Future<void> setDayVehicle(String userId, String vehicleId) async {
  try {
    await (await SharedPreferences.getInstance()).setString('day_vehicle_$userId', '${_today()}|$vehicleId');
  } catch (_) {/* sin almacenamiento: se volverá a preguntar */}
}
