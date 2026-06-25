// Guarda/descarga un fichero generado (Excel/PDF) de forma multiplataforma.
//   - Web: dispara la descarga del navegador (Blob + enlace).
//   - Android/iOS/desktop: lo escribe en disco y lo abre con la app del sistema.
// Import condicional para no romper la compilación web con dart:io.
export 'file_download_io.dart' if (dart.library.html) 'file_download_web.dart';
