import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../config.dart';

/// Información de una actualización disponible.
class UpdateInfo {
  final int latestCode;
  final String latestName;
  final String apkUrl;
  final String notes;
  /// true si la versión instalada es demasiado antigua (puede dar problemas al
  /// guardar): al cerrar el aviso, conviene advertir del riesgo.
  final bool mandatory;
  const UpdateInfo({
    required this.latestCode,
    required this.latestName,
    required this.apkUrl,
    required this.notes,
    required this.mandatory,
  });
}

/// Comprueba si hay una versión más nueva publicada (solo Android sideload).
/// Devuelve null si no hay novedad, si es web, o si no se puede comprobar.
class UpdateService {
  static Future<UpdateInfo?> check() async {
    if (kIsWeb) return null; // la web siempre sirve la última, no aplica
    try {
      final info = await PackageInfo.fromPlatform();
      final currentCode = int.tryParse(info.buildNumber) ?? 0;

      final res = await http
          .get(Uri.parse(updateManifestUrl))
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      final m = jsonDecode(res.body) as Map<String, dynamic>;

      final latestCode = (m['latest_code'] as num?)?.toInt() ?? 0;
      if (latestCode <= currentCode) return null; // ya está al día

      final minSupported = (m['min_supported_code'] as num?)?.toInt() ?? 0;
      return UpdateInfo(
        latestCode: latestCode,
        latestName: (m['latest_name'] as String?) ?? '',
        apkUrl: (m['apk_url'] as String?) ?? '',
        notes: (m['notes'] as String?) ?? '',
        mandatory: currentCode < minSupported,
      );
    } catch (_) {
      return null; // sin red o manifiesto no disponible: no molestamos
    }
  }
}
