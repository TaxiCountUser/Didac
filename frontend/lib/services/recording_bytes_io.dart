import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Nativo (Android/iOS/desktop): `path` es una ruta de fichero local.
Future<List<int>> readRecordingBytes(String path) => File(path).readAsBytes();

/// Ruta ABSOLUTA donde grabar. En Android `record` exige una ruta absoluta;
/// pasar solo un nombre de fichero hacía fallar la grabación (y la app se
/// cerraba al transcribir). Usamos el directorio temporal de la app.
Future<String> recordingPath(String filename) async {
  final dir = await getTemporaryDirectory();
  return '${dir.path}/$filename';
}
