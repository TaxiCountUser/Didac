import 'dart:async';
import 'dart:typed_data';

import 'package:record_platform_interface/record_platform_interface.dart';

/// Implementación no-op de `record` para Linux (escritorio no soportado).
/// Solo existe para que la compilación en hosts Linux funcione; nunca se ejecuta
/// porque TaxiCount se usa en Android y web. Sustituye al record_linux oficial
/// (abandonado en 0.7.2) vía dependency_overrides.
class RecordLinux extends RecordPlatform {
  static void registerWith() {
    RecordPlatform.instance = RecordLinux();
  }

  Never _unsupported() =>
      throw UnsupportedError('La grabación de audio no está soportada en escritorio.');

  @override
  Future<void> create(String recorderId) async {}

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async => false;

  @override
  Future<bool> isPaused(String recorderId) async => false;

  @override
  Future<bool> isRecording(String recorderId) async => false;

  @override
  Future<void> pause(String recorderId) async {}

  @override
  Future<void> resume(String recorderId) async {}

  @override
  Future<void> start(String recorderId, RecordConfig config, {required String path}) async =>
      _unsupported();

  @override
  Future<Stream<Uint8List>> startStream(String recorderId, RecordConfig config) async =>
      _unsupported();

  @override
  Future<String?> stop(String recorderId) async => null;

  @override
  Future<void> cancel(String recorderId) async {}

  @override
  Future<void> dispose(String recorderId) async {}

  @override
  Future<Amplitude> getAmplitude(String recorderId) async =>
      Amplitude(current: 0.0, max: 0.0);

  @override
  Future<bool> isEncoderSupported(String recorderId, AudioEncoder encoder) async => false;

  @override
  Future<List<InputDevice>> listInputDevices(String recorderId) async => const [];

  @override
  Stream<RecordState> onStateChanged(String recorderId) => const Stream.empty();
}
