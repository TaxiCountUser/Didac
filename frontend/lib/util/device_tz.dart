import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'device_tz_stub.dart' if (dart.library.js_interop) 'device_tz_web.dart';

/// Zona horaria (IANA, p. ej. 'Europe/Madrid' o 'Atlantic/Canary') del móvil o del
/// navegador: la MISMA con la que la app enseña las horas (`toLocal()`). Se manda
/// al pedir un informe para que el Excel/PDF digan exactamente la misma hora que
/// la app. null si no se puede saber (el backend usa entonces la hora de España).
Future<String?> deviceTimeZone() async {
  if (kIsWeb) return webTimeZone();
  if (defaultTargetPlatform == TargetPlatform.android) {
    try {
      // MainActivity.kt -> TimeZone.getDefault().id
      return await const MethodChannel('taxicount/notify').invokeMethod<String>('timezone');
    } catch (_) {}
  }
  return null;
}
