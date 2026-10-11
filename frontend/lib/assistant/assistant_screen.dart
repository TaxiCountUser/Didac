import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import 'assistant_engine.dart';

/// Asistente virtual (Ajustes → "Asistente virtual"). Parece una IA pero es un
/// bot de preguntas frecuentes (assistant_engine.dart), sin coste de tokens:
/// "piensa" unos segundos, responde, pregunta si ha servido y, si no lo consigue
/// (3 intentos fallidos o la misma respuesta 2 veces), ofrece crear un ticket que
/// llega al chat de Soporte del admin. Aprende: lo que no entendió y después sí
/// sirvió se guarda como sinónimo (backend /assistant/feedback).
class AssistantScreen extends StatefulWidget {
  final Profile profile;
  /// Pantallas a las que el bot puede llevar ("Ir allí"): clave -> abrir.
  final Map<String, VoidCallback> actions;
  const AssistantScreen({super.key, required this.profile, this.actions = const {}});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

enum _ChipKind { ask, pick, yes, no, ticketYes, ticketNo, go, tutorial, tickets }

class _Chip {
  final _ChipKind kind;
  final String label;
  final String? value;
  const _Chip(this.kind, this.label, [this.value]);
}

class _Msg {
  final bool bot;
  final String text;
  final List<_Chip> chips;
  bool chipsActive = true;
  _Msg(this.bot, this.text, [this.chips = const []]);
}

class _AssistantScreenState extends State<AssistantScreen> {
  final _service = DataService();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _rnd = Random();
  final _msgs = <_Msg>[];
  late final String _lang = const {'es', 'ca', 'en'}.contains(localeController.value.languageCode)
      ? localeController.value.languageCode
      : 'es';
  late final String _role = widget.profile.isOwner ? 'owner' : 'driver';
  late final String _conversationId = _uuid();

  AssistantKb? _kb;
  AssistantEngine? _engine;
  bool _typing = false;
  bool _awaitTicket = false; // el siguiente mensaje es el texto del ticket
  int _strikes = 0; // intentos sin éxito desde el último "me ha servido"
  final _timesAnswered = <String, int>{}; // misma respuesta dada N veces
  final _pendingLearn = <String>[]; // preguntas no resueltas (para aprender)
  String? _lastLogId;
  KbEntry? _lastEntry;
  String? _lastQuestion;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String _uuid() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  Future<void> _load() async {
    final seed = jsonDecode(await rootBundle.loadString('assets/assistant/kb.json')) as Map<String, dynamic>;
    final remote = await _service.assistantRemoteKb();
    final kb = AssistantKb.build(seed, remote);
    if (!mounted) return;
    setState(() {
      _kb = kb;
      _engine = AssistantEngine(kb);
    });
    final h = DateTime.now().hour;
    final greet = switch (_lang) {
      'ca' => h < 13 ? 'Bon dia' : (h < 20 ? 'Bona tarda' : 'Bona nit'),
      'en' => h < 12 ? 'Good morning' : (h < 20 ? 'Good afternoon' : 'Good evening'),
      _ => h < 13 ? 'Buenos días' : (h < 20 ? 'Buenas tardes' : 'Buenas noches'),
    };
    final name = widget.profile.appName.split(' ').first.split('@').first;
    final starters = kb.entries.values.where((e) => e.starter && e.forRole(_role)).take(5)
        .map((e) => _Chip(_ChipKind.ask, e.title(_lang))).toList();
    await _say(_say1('hello', {'greet': greet, 'name': name}), short: true);
    await _say(_say1('starters'), chips: starters, short: true);
  }

  String _say1(String key, [Map<String, String> args = const {}]) => _kb!.say(_lang, key, args, _rnd);

  // El bot "piensa": indicador de escritura un tiempo proporcional a la respuesta.
  Future<void> _say(String text, {List<_Chip> chips = const [], bool short = false}) async {
    if (text.trim().isEmpty && chips.isEmpty) return;
    setState(() => _typing = true);
    _toBottom();
    final ms = short
        ? 500 + _rnd.nextInt(500)
        : 1000 + _rnd.nextInt(900) + min<int>(text.length * 6, 1300);
    await Future.delayed(Duration(milliseconds: ms));
    if (!mounted) return;
    setState(() {
      _typing = false;
      _msgs.add(_Msg(true, text.trim(), chips));
    });
    _toBottom();
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent + 120,
              duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        }
      });

  void _disableChips() {
    for (final m in _msgs) {
      m.chipsActive = false;
    }
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _typing || _engine == null) return;
    _input.clear();
    setState(() {
      _disableChips();
      _msgs.add(_Msg(false, text));
    });
    _toBottom();
    if (_awaitTicket) return _createTicket(text);
    await _handleQuestion(text);
  }

  Future<String?> _log(String q, {String? matched, double? score, required String outcome}) =>
      _service.assistantLog({
        'conversation_id': _conversationId,
        'lang': _lang,
        'question': q,
        'matched_id': matched,
        'score': score,
        'outcome': outcome,
      });

  Future<void> _handleQuestion(String q) async {
    final related = _lastEntry?.related.toSet() ?? const <String>{};
    final res = _engine!.search(q, lang: _lang, role: _role, boost: {...related, if (_lastEntry != null) _lastEntry!.id});
    final top = res.isEmpty ? null : res.first;
    _lastQuestion = q;

    // Charla: hola / gracias / adiós / ¿quién eres?
    if (top != null && top.entry.cat == 'smalltalk') {
      unawaited(_log(q, matched: top.entry.id, score: top.score, outcome: 'answered'));
      return _say(top.entry.answer(_lang));
    }
    // "Quiero hablar con una persona / crear un ticket"
    if (top != null && top.entry.id == 'human' && top.score >= 0.45) {
      unawaited(_log(q, matched: 'human', score: top.score, outcome: 'answered'));
      await _say(top.entry.answer(_lang), short: true);
      return _offerTicket(direct: true);
    }
    if (top != null && top.score >= 0.5) {
      return _answer(q, top.entry, top.score);
    }
    _pendingLearn.add(q);
    _strikes++;
    final options = res.where((m) => m.score >= 0.25 && m.entry.cat != 'smalltalk' && m.entry.id != 'human')
        .take(3).toList();
    unawaited(_log(q, matched: null, score: top?.score, outcome: 'no_match'));
    if (_strikes >= 3) return _offerTicket();
    if (options.isNotEmpty) {
      return _say(_say1('clarify'),
          chips: options.map((m) => _Chip(_ChipKind.pick, m.entry.title(_lang), m.entry.id)).toList());
    }
    await _say(_say1('not_understood'));
  }

  Future<void> _answer(String q, KbEntry e, double score) async {
    final l = context.l10n;
    final n = (_timesAnswered[e.id] ?? 0) + 1;
    _timesAnswered[e.id] = n;
    _lastEntry = e;
    if (n >= 2) {
      // La misma respuesta otra vez: no repetirse, proponer el ticket.
      _pendingLearn.add(q);
      unawaited(_log(q, matched: e.id, score: score, outcome: 'not_helpful'));
      await _say(_say1('same_again'), short: true);
      return _offerTicket();
    }
    _lastLogId = await _log(q, matched: e.id, score: score, outcome: 'answered');
    final chips = <_Chip>[
      if (e.action != null && widget.actions.containsKey(e.action)) _Chip(_ChipKind.go, l.t('asst_go'), e.action),
      if (e.tutorial != null) _Chip(_ChipKind.tutorial, l.t('asst_tutorial'), e.tutorial),
    ];
    await _say('${_say1('intro')}${e.answer(_lang)}', chips: chips);
    await _say(_say1('ask_helpful'), short: true, chips: [
      _Chip(_ChipKind.yes, l.t('asst_yes')),
      _Chip(_ChipKind.no, l.t('asst_no')),
    ]);
  }

  Future<void> _offerTicket({bool direct = false}) async {
    final l = context.l10n;
    await _say(direct ? '' : _say1('offer_ticket'), short: direct, chips: [
      _Chip(_ChipKind.ticketYes, l.t('asst_ticket_yes')),
      _Chip(_ChipKind.ticketNo, l.t('asst_ticket_no')),
    ]);
  }

  Future<void> _createTicket(String text) async {
    if (text.length < 15) return _say(_say1('ticket_short'), short: true);
    final l = context.l10n;
    final transcript = _msgs
        .take(_msgs.length - 1)
        .where((m) => m.text.isNotEmpty)
        .toList()
        .reversed
        .take(14)
        .toList()
        .reversed
        .map((m) => '${m.bot ? '🤖' : '👤'} ${m.text.length > 220 ? '${m.text.substring(0, 220)}…' : m.text}')
        .join('\n');
    final body = '$text\n\n— ${l.t('asst_transcript')} —\n$transcript';
    setState(() => _typing = true);
    try {
      if (widget.profile.tenantId.isEmpty) throw Exception('no tenant');
      await _service.createTicket(widget.profile.tenantId, body);
      unawaited(_log(text, outcome: 'ticket'));
      _awaitTicket = false;
      _strikes = 0;
      _timesAnswered.clear();
      if (mounted) setState(() => _typing = false);
      await _say(_say1('ticket_done'),
          chips: [if (widget.actions.containsKey('tickets')) _Chip(_ChipKind.tickets, l.t('asst_my_tickets'))]);
    } catch (_) {
      if (mounted) setState(() => _typing = false);
      await _say(_say1('ticket_error'));
    }
  }

  Future<void> _onChip(_Msg msg, _Chip c) async {
    if (!msg.chipsActive || _typing) return;
    switch (c.kind) {
      case _ChipKind.go:
        widget.actions[c.value]?.call();
        return; // no consume los demás chips
      case _ChipKind.tutorial:
        await launchUrl(Uri.parse(c.value!), mode: LaunchMode.externalApplication);
        return;
      case _ChipKind.tickets:
        widget.actions['tickets']?.call();
        return;
      default:
        break;
    }
    setState(() {
      _disableChips();
      _msgs.add(_Msg(false, c.label));
    });
    _toBottom();
    switch (c.kind) {
      case _ChipKind.ask:
        await _handleQuestion(c.label);
      case _ChipKind.pick:
        final e = _kb!.entries[c.value];
        if (e != null) await _answer(_lastQuestion ?? c.label, e, 0.5);
      case _ChipKind.yes:
        if (_lastLogId != null) {
          // Solo se aprenden preguntas que antes NO se entendieron (o fallaron).
          unawaited(_service.assistantFeedback(_lastLogId!, true, learn: _pendingLearn.toList()));
        }
        _pendingLearn.clear();
        _strikes = 0;
        _timesAnswered.clear();
        final rel = (_lastEntry?.related ?? const <String>[])
            .map((id) => _kb!.entries[id])
            .whereType<KbEntry>()
            .take(3)
            .map((e) => _Chip(_ChipKind.ask, e.title(_lang)))
            .toList();
        await _say(_say1('glad'), short: true);
        if (rel.isNotEmpty) await _say(_say1('related'), chips: rel, short: true);
      case _ChipKind.no:
        if (_lastLogId != null) unawaited(_service.assistantFeedback(_lastLogId!, false));
        if (_lastQuestion != null) _pendingLearn.add(_lastQuestion!);
        _strikes++;
        if (_strikes >= 2) return _offerTicket();
        await _say(_say1('retry'));
      case _ChipKind.ticketYes:
        _awaitTicket = true;
        await _say(_say1('ticket_ask'));
      case _ChipKind.ticketNo:
        _strikes = 0;
        _timesAnswered.clear();
        await _say(_say1('ticket_declined'), short: true);
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(children: [
          const _BotAvatar(size: 36),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.t('asst_title'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            Row(children: [
              Container(width: 7, height: 7,
                  decoration: const BoxDecoration(color: Colors.green, shape: BoxShape.circle)),
              const SizedBox(width: 5),
              Text(_typing ? l.t('asst_typing') : l.t('asst_online'),
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ]),
          ]),
        ]),
      ),
      body: Column(children: [
        Expanded(
          child: _kb == null
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  itemCount: _msgs.length + (_typing ? 1 : 0),
                  itemBuilder: (_, i) => i == _msgs.length ? const _TypingBubble() : _bubble(_msgs[i], cs),
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 300,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: _awaitTicket ? l.t('asst_ticket_hint') : l.t('asst_hint'),
                    counterText: '',
                    isDense: true,
                    filled: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton.filled(
                tooltip: l.t('asst_send'),
                onPressed: _typing ? null : _send,
                icon: const Icon(Icons.send_rounded),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _bubble(_Msg m, ColorScheme cs) {
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: m.bot ? cs.surfaceContainerHighest : cs.primary,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(m.bot ? 4 : 16),
          bottomRight: Radius.circular(m.bot ? 16 : 4),
        ),
      ),
      child: Text(m.text, style: TextStyle(color: m.bot ? cs.onSurface : cs.onPrimary, height: 1.35)),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: m.bot ? CrossAxisAlignment.start : CrossAxisAlignment.end,
        children: [
          if (m.text.isNotEmpty)
            Row(
              mainAxisAlignment: m.bot ? MainAxisAlignment.start : MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (m.bot) ...[const _BotAvatar(size: 26), const SizedBox(width: 6)],
                Flexible(child: bubble),
              ],
            ),
          if (m.chips.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(left: m.bot ? 32 : 0, top: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: m.chips.map((c) {
                  final enabled = m.chipsActive || c.kind == _ChipKind.go ||
                      c.kind == _ChipKind.tutorial || c.kind == _ChipKind.tickets;
                  return ActionChip(
                    avatar: switch (c.kind) {
                      _ChipKind.go => const Icon(Icons.open_in_new, size: 16),
                      _ChipKind.tutorial => const Icon(Icons.play_circle_outline, size: 16),
                      _ChipKind.tickets => const Icon(Icons.support_agent, size: 16),
                      _ChipKind.yes => const Icon(Icons.thumb_up_alt_outlined, size: 16),
                      _ChipKind.no => const Icon(Icons.thumb_down_alt_outlined, size: 16),
                      _ChipKind.ticketYes => const Icon(Icons.confirmation_number_outlined, size: 16),
                      _ => null,
                    },
                    label: Text(c.label),
                    onPressed: enabled ? () => _onChip(m, c) : null,
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }
}

class _BotAvatar extends StatelessWidget {
  final double size;
  const _BotAvatar({required this.size});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(colors: [Color(0xFFFFC107), Color(0xFFFF8F00)]),
        ),
        child: Icon(Icons.auto_awesome, size: size * 0.55, color: Colors.white),
      );
}

/// Tres puntos que "laten" mientras el bot escribe.
class _TypingBubble extends StatefulWidget {
  const _TypingBubble();
  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        const _BotAvatar(size: 26),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, __) => Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (i) {
                final t = ((_c.value - i * 0.18) % 1.0);
                final o = 0.3 + 0.7 * (t < 0.5 ? t * 2 : (1 - t) * 2);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Opacity(
                    opacity: o.clamp(0.3, 1.0),
                    child: Container(width: 7, height: 7,
                        decoration: BoxDecoration(color: cs.onSurfaceVariant, shape: BoxShape.circle)),
                  ),
                );
              }),
            ),
          ),
        ),
      ]),
    );
  }
}
