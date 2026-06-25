// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

/// Web: crea un Blob con los bytes y dispara la descarga del navegador.
Future<void> saveAndOpenDownload(List<int> bytes, String filename) async {
  final blob = html.Blob(<dynamic>[bytes]);
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..download = filename
    ..click();
  html.Url.revokeObjectUrl(url);
}
