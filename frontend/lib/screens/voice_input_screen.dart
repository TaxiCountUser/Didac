import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../models/profile.dart';
import '../services/data_service.dart';
import '../services/recording_bytes.dart';
import 'transaction_preview_screen.dart';

/// Grabación de voz -> transcripción (backend/Whisper) -> previsualización.
class VoiceInputScreen extends StatefulWidget {
  final Profile profile;
  const VoiceInputScreen({super.key, required this.profile});

  @override
  State<VoiceInputScreen> createState() => _VoiceInputScreenState();
}

class _VoiceInputScreenState extends State<VoiceInputScreen> {
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
        setState(() => _error = 'Sin permiso de micrófono');
        return;
      }
      await _recorder.start(const RecordConfig(), path: 'voice_note.m4a');
      setState(() => _recording = true);
    } catch (e) {
      setState(() => _error = 'No se pudo iniciar la grabación: $e');
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
      if (path == null) throw Exception('No se grabó audio');

      // En web `path` es un blob URL; en Android/iOS es una ruta de fichero.
      // El helper lee los bytes según la plataforma (la APK fallaba al hacer
      // http.get sobre una ruta de fichero local).
      final bytes = await readRecordingBytes(path);

      final res = await DataService().transcribe(audioBytes: bytes, filename: 'voice_note.m4a');
      final parsed = Map<String, dynamic>.from(res['parsed'] as Map);
      parsed['description'] = res['text'];

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => TransactionPreviewScreen(profile: widget.profile, parsed: parsed),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Error al transcribir: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dictar transacción')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_busy) ...[
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                const Text('Transcribiendo…'),
              ] else ...[
                Text(
                  _recording ? 'Grabando… pulsa para terminar' : 'Pulsa el micrófono y dicta',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                GestureDetector(
                  onTap: _recording ? _stopAndTranscribe : _start,
                  child: CircleAvatar(
                    radius: 56,
                    backgroundColor: _recording ? Colors.red : Colors.amber,
                    child: Icon(_recording ? Icons.stop : Icons.mic,
                        size: 56, color: Colors.white),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 24),
                Text(_error!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    OutlinedButton(
                      onPressed: () => setState(() {
                        _error = null;
                        _busy = false;
                      }),
                      child: const Text('Reintentar'),
                    ),
                    const SizedBox(width: 12),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Modo manual'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
