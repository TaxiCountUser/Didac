import 'dart:io';

/// Nativo (Android/iOS/desktop): `path` es una ruta de fichero local.
Future<List<int>> readRecordingBytes(String path) => File(path).readAsBytes();
