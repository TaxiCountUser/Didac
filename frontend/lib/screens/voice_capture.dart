import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import '../services/recording_bytes.dart';

/// Captura de voz reutilizable: graba, transcribe (backend/Whisper) y entrega
/// el resultado parseado vía [onParsed]. No navega: el contenedor decide qué
/// hacer (p. ej. rellenar el formulario manual para confirmar).
class VoiceCapture extends StatefulWidget {
  final void Function(Map<String, dynamic> parsed) onParsed;
  final bool autoStart; // empezar a grabar nada más abrir (atajo de voz)
  const VoiceCapture({super.key, required this.onParsed, this.autoStart = false});

  @override
  State<VoiceCapture> createState() => _VoiceCaptureState();
}

class _VoiceCaptureState extends State<VoiceCapture> {
  final _recorder = AudioRecorder();
  bool _recording = false;
  bool _busy = false;
  String? _error;
  // Ondas de voz en vivo: nivel de amplitud reciente (ventana móvil) para que se
  // vea claramente que ESTÁ grabando. En web el plugin `record` NO emite
  // amplitud, así que un timer anima las barras (con la amplitud real cuando
  // llega —móvil— o un patrón sintético cuando no —web—).
  StreamSubscription<Amplitude>? _ampSub;
  Timer? _waveTimer;
  // OJO: growable:true. Con una lista de longitud fija, removeAt/add lanzan y el
  // timer de la onda moría en silencio -> barras siempre planas (línea de puntos).
  final List<double> _levels = List.filled(28, 0.0, growable: true);
  double _currentReal = 0; // última amplitud real normalizada (0..1)
  DateTime? _lastAmpAt;     // cuándo llegó (para saber si hay amplitud real)
  int _waveTick = 0;

  @override
  void initState() {
    super.initState();
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    }
  }

  @override
  void dispose() {
    _ampSub?.cancel();
    _waveTimer?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _error = null);
    try {
      if (!await _recorder.hasPermission()) {
        setState(() => _error = context.l10n.t('vc_no_perm'));
        return;
      }
      // En Android la ruta debe ser absoluta; recordingPath la resuelve.
      final out = await recordingPath('voice_note.m4a');
      await _recorder.start(const RecordConfig(), path: out);
      // Reinicia el estado de la onda para esta grabación.
      _waveTick = 0;
      _lastAmpAt = null;
      // Suscripción a la amplitud (dBFS) para la onda real (móvil).
      _ampSub?.cancel();
      _ampSub = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 90))
          .listen(_onAmplitude, onError: (_) {});
      // Timer que ANIMA la onda a 90 ms: usa la amplitud real si es reciente; si
      // no (web, sin amplitud), genera un patrón que se mueve para indicar que graba.
      _waveTimer?.cancel();
      _waveTimer = Timer.periodic(const Duration(milliseconds: 90), _tickWave);
      setState(() => _recording = true);
    } catch (e) {
      setState(() => _error = '${context.l10n.t('vc_start_fail')}: $e');
    }
  }

  void _onAmplitude(Amplitude amp) {
    final db = amp.current;
    if (!db.isFinite) return;
    // amp.current es dBFS: ~-160 en silencio, ~-25 hablando, ~-5 muy fuerte
    // (medido en dispositivo). Mapeamos el rango ÚTIL de voz (-50..-10 dB) a
    // 0..1: en silencio queda plano y al hablar sube según el volumen.
    _currentReal = ((db + 50) / 40).clamp(0.0, 1.0);
    _lastAmpAt = DateTime.now();
  }

  void _tickWave(Timer _) {
    if (!mounted || !_recording) return;
    _waveTick++;
    final hasReal = _lastAmpAt != null &&
        DateTime.now().difference(_lastAmpAt!).inMilliseconds < 300;
    double level;
    if (hasReal) {
      // Móvil: la onda REACCIONA a la voz (baja en silencio, sube al hablar).
      level = _currentReal.clamp(0.02, 1.0);
    } else {
      // Web (el plugin no emite amplitud): patrón sintético para indicar que graba.
      final t = _waveTick * 0.55;
      final wave = (math.sin(t) + math.sin(t * 1.7 + 1)) / 2; // -1..1
      level = (0.20 + 0.35 * ((wave + 1) / 2)).clamp(0.08, 1.0);
    }
    setState(() {
      _levels.removeAt(0);
      _levels.add(level);
    });
  }

  Future<void> _stopAndTranscribe() async {
    final l = context.l10n; // capturado antes de los await (lint async-gap)
    _ampSub?.cancel();
    _ampSub = null;
    _waveTimer?.cancel();
    _waveTimer = null;
    setState(() {
      _recording = false;
      _busy = true;
      _error = null;
    });
    try {
      final path = await _recorder.stop();
      if (path == null) throw Exception(l.t('vc_no_audio'));

      // En web `path` es un blob URL; en Android/iOS es una ruta de fichero.
      // El helper lee los bytes según la plataforma (antes la APK fallaba
      // porque intentaba http.get sobre una ruta de fichero local).
      final bytes = await readRecordingBytes(path);

      final res = await DataService().transcribe(
        audioBytes: bytes,
        filename: 'voice_note.m4a',
        language: localeController.value.languageCode, // es / ca / en
      );
      final parsed = Map<String, dynamic>.from(res['parsed'] as Map);
      parsed['description'] = res['text'];

      if (!mounted) return;
      setState(() => _busy = false);
      if (res['mock'] == true) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.l10n.t('vc_mock'))));
      }
      widget.onParsed(parsed);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '${context.l10n.t('vc_transcribe_err')}: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_busy) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(l.t('vc_transcribing')),
            ] else ...[
              Text(
                _recording ? l.t('vc_recording') : l.t('vc_tap'),
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                l.t('vc_example'),
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              // Onda de voz en vivo: solo mientras graba (indica claramente que
              // el micrófono está capturando).
              if (_recording)
                SizedBox(
                  height: 48,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      for (final level in _levels)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 90),
                          width: 4,
                          height: 4 + 44 * level,
                          margin: const EdgeInsets.symmetric(horizontal: 1.5),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.4 + 0.6 * level),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 24),
              GestureDetector(
                key: const Key('voice_capture_button'),
                onTap: _recording ? _stopAndTranscribe : _start,
                child: CircleAvatar(
                  radius: 56,
                  backgroundColor: _recording ? Colors.red : Colors.amber,
                  child: Icon(_recording ? Icons.stop : Icons.mic, size: 56, color: Colors.white),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 24),
              Text(_error!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => setState(() {
                  _error = null;
                  _busy = false;
                }),
                child: Text(l.t('retry')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
