import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';

/// Captura de voz reutilizable: graba, transcribe (backend/Whisper) y entrega
/// el resultado parseado vía [onParsed]. No navega: el contenedor decide qué
/// hacer (p. ej. rellenar el formulario manual para confirmar).
class VoiceCapture extends StatefulWidget {
  final void Function(Map<String, dynamic> parsed) onParsed;
  const VoiceCapture({super.key, required this.onParsed});

  @override
  State<VoiceCapture> createState() => _VoiceCaptureState();
}

class _VoiceCaptureState extends State<VoiceCapture> {
  final _recorder = AudioRecorder();
  bool _recording = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
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
      await _recorder.start(const RecordConfig(), path: 'voice_note.m4a');
      setState(() => _recording = true);
    } catch (e) {
      setState(() => _error = '${context.l10n.t('vc_start_fail')}: $e');
    }
  }

  Future<void> _stopAndTranscribe() async {
    setState(() {
      _recording = false;
      _busy = true;
      _error = null;
    });
    try {
      final path = await _recorder.stop();
      if (path == null) throw Exception(context.l10n.t('vc_no_audio'));

      // En web el path es un blob URL; leemos los bytes vía http.
      final bytes = (await http.get(Uri.parse(path))).bodyBytes;

      final res = await DataService().transcribe(audioBytes: bytes, filename: 'voice_note.m4a');
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
