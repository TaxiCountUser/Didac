import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import '../services/recording_bytes.dart';

/// Botón de micrófono para dictar texto. Graba, transcribe (backend/Whisper) y
/// entrega el texto reconocido vía [onText]. Pensado para el compositor de un
/// chat: el texto se añade a lo que ya hay escrito.
class DictateButton extends StatefulWidget {
  final void Function(String text) onText;
  const DictateButton({super.key, required this.onText});

  @override
  State<DictateButton> createState() => _DictateButtonState();
}

class _DictateButtonState extends State<DictateButton> {
  final _recorder = AudioRecorder();
  bool _recording = false;
  bool _busy = false;

  @override
  void dispose() {
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final l = context.l10n;
    try {
      if (!await _recorder.hasPermission()) {
        _snack(l.t('vc_no_perm'));
        return;
      }
      final out = await recordingPath('voice_note.m4a');
      await _recorder.start(const RecordConfig(), path: out);
      if (mounted) setState(() => _recording = true);
    } catch (e) {
      _snack('${l.t('vc_start_fail')}: $e');
    }
  }

  Future<void> _stopAndTranscribe() async {
    final l = context.l10n;
    setState(() {
      _recording = false;
      _busy = true;
    });
    try {
      final path = await _recorder.stop();
      if (path == null) throw Exception(l.t('vc_no_audio'));
      final bytes = await readRecordingBytes(path);
      final res = await DataService().transcribe(
        audioBytes: bytes,
        filename: 'voice_note.m4a',
        language: localeController.value.languageCode,
      );
      final text = (res['text'] as String?)?.trim() ?? '';
      if (!mounted) return;
      setState(() => _busy = false);
      if (text.isNotEmpty) widget.onText(text);
      if (res['mock'] == true) _snack(l.t('vc_mock'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('${l.t('vc_transcribe_err')}: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return IconButton(
      tooltip: context.l10n.t(_recording ? 'dictate_stop' : 'dictate_start'),
      onPressed: _recording ? _stopAndTranscribe : _start,
      icon: Icon(_recording ? Icons.stop : Icons.mic,
          color: _recording ? Colors.red : null),
    );
  }
}
