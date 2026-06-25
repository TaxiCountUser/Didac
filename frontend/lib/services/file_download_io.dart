import 'dart:io';

import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

/// Nativo: escribe el fichero en el directorio temporal y lo abre.
Future<void> saveAndOpenDownload(List<int> bytes, String filename) async {
  final dir = await getTemporaryDirectory();
  final path = '${dir.path}/$filename';
  await File(path).writeAsBytes(bytes, flush: true);
  await OpenFilex.open(path);
}
