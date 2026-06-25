// Lee los bytes de una grabación de voz de forma multiplataforma.
//
// El paquete `record` devuelve cosas distintas según la plataforma al llamar a
// `stop()`:
//   - Web:    una URL `blob:` que hay que descargar por http.
//   - Android/iOS/desktop: una ruta a un fichero local en disco.
//
// Por eso usamos import condicional: en web usamos la versión http, en nativo
// leemos el fichero con dart:io. Así la APK puede transcribir (antes fallaba
// porque intentaba hacer http.get de una ruta de fichero local).
export 'recording_bytes_io.dart' if (dart.library.html) 'recording_bytes_web.dart';
