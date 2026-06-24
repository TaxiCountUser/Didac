import 'package:geolocator/geolocator.dart';

/// Acceso a la ubicación del dispositivo (con manejo de permisos).
class LocationService {
  /// Posición actual si hay servicio + permiso; null si no se puede obtener.
  static Future<Position?> currentPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
    } catch (_) {
      return null;
    }
  }

  /// Asegura permiso y devuelve un stream de posiciones (seguimiento continuo
  /// mientras la app esté abierta). null si no hay permiso/servicio.
  static Future<Stream<Position>?> positionStream() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        return null;
      }
      return Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 20),
      );
    } catch (_) {
      return null;
    }
  }
}
