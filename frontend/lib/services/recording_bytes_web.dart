import 'package:http/http.dart' as http;

/// Web: `path` es una URL `blob:`; descargamos los bytes por http.
Future<List<int>> readRecordingBytes(String path) async =>
    (await http.get(Uri.parse(path))).bodyBytes;
