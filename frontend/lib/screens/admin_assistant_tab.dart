import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../assistant/assistant_engine.dart';
import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import 'admin_theme.dart';

/// Soporte → pestaña "Asistente": cómo va el bot de preguntas frecuentes y
/// enseñarle. Tres vistas: preguntas que NO supo responder (enseñar a una
/// respuesta existente, crear una nueva o descartar) · todas las respuestas
/// (semilla del JSON + editadas por el admin; editar/ocultar/restaurar) · frases
/// aprendidas (olvidar si aprendió algo mal). Backend: /admin/assistant/* (mig. 087).
class AssistantAdminTab extends StatefulWidget {
  const AssistantAdminTab({super.key});
  @override
  State<AssistantAdminTab> createState() => _AssistantAdminTabState();
}

class _AssistantAdminTabState extends State<AssistantAdminTab> {
  final _service = DataService();
  int _days = 30;
  int _view = 0; // 0 sin respuesta · 1 respuestas · 2 aprendido
  late Future<_Data> _future = _load();

  Future<_Data> _load() async {
    final seed = jsonDecode(await rootBundle.loadString('assets/assistant/kb.json')) as Map<String, dynamic>;
    final res = await Future.wait([_service.adminAssistantSummary(days: _days), _service.adminAssistantEntries()]);
    return _Data(seed, res[0], res[1]);
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _run(Future<void> Function() f, {String? ok}) async {
    try {
      await f();
      if (mounted && ok != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok)));
      _reload();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return FutureBuilder<_Data>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        if (snap.hasError) {
          return Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('${snap.error}', style: const TextStyle(color: AdminColors.red, fontSize: 12)),
              TextButton(onPressed: _reload, child: Text(l.t('retry'))),
            ]),
          );
        }
        final d = snap.data!;
        final s = d.summary;
        int n(String k) => (s[k] as num?)?.toInt() ?? 0;
        final total = n('total');
        final pct = total == 0 ? '—' : '${(n('answered') * 100 / total).round()}%';
        final unanswered = ((s['unanswered'] as List?) ?? const []).cast<Map<String, dynamic>>();
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
          children: [
            SizedBox(
              height: 34,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final dd in const [7, 30, 90]) ...[
                  AdminPill(label: '$dd d', selected: _days == dd, color: AdminColors.amber,
                      onTap: () { _days = dd; _reload(); }),
                  const SizedBox(width: 6),
                ],
              ]),
            ),
            adminSectionTitle(l.t('adm_asst_kpis'), color: AdminColors.amber),
            SizedBox(
              height: 54,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                AdminKpiChip(label: l.t('adm_asst_questions'), value: '$total', color: AdminColors.blue),
                const SizedBox(width: 8),
                AdminKpiChip(label: l.t('adm_asst_answered'), value: pct, color: AdminColors.teal),
                const SizedBox(width: 8),
                AdminKpiChip(label: l.t('adm_asst_helpful'), value: '${n('helpful')}', color: AdminColors.teal),
                const SizedBox(width: 8),
                AdminKpiChip(label: l.t('adm_asst_not_helpful'), value: '${n('not_helpful')}', color: AdminColors.coral),
                const SizedBox(width: 8),
                AdminKpiChip(label: l.t('adm_asst_tickets'), value: '${n('tickets')}', color: AdminColors.purple),
              ]),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 34,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                AdminPill(label: '${l.t('adm_asst_unanswered')} (${unanswered.length})', selected: _view == 0,
                    color: AdminColors.red, onTap: () => setState(() => _view = 0)),
                const SizedBox(width: 6),
                AdminPill(label: '${l.t('adm_asst_entries')} (${d.kb.entries.length})', selected: _view == 1,
                    color: AdminColors.blue, onTap: () => setState(() => _view = 1)),
                const SizedBox(width: 6),
                AdminPill(label: '${l.t('adm_asst_learned')} (${d.learned.length})', selected: _view == 2,
                    color: AdminColors.teal, onTap: () => setState(() => _view = 2)),
              ]),
            ),
            const SizedBox(height: 8),
            ...switch (_view) {
              0 => _unanswered(l, d, unanswered),
              1 => _entries(l, d),
              _ => _learned(l, d),
            },
          ],
        );
      },
    );
  }

  // ---------- Sin respuesta ----------
  List<Widget> _unanswered(AppLocalizations l, _Data d, List<Map<String, dynamic>> list) {
    if (list.isEmpty) {
      return [Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(l.t('adm_asst_none'))))];
    }
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(l.t('adm_asst_unanswered_help'), style: const TextStyle(fontSize: 11, color: AdminColors.secondary)),
      ),
      for (final u in list)
        Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 6),
          decoration: adminCardBox(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              AdminTag('×${u['count']}', fg: AdminColors.red, bg: AdminColors.redBg),
              const SizedBox(width: 8),
              Expanded(child: Text('${u['example']}', style: const TextStyle(fontSize: 13, color: AdminColors.text))),
              Text('${u['lang'] ?? ''}', style: const TextStyle(fontSize: 10, color: AdminColors.muted)),
            ]),
            if (u['gave'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${l.t('adm_asst_gave')}: ${d.kb.entries[u['gave']]?.title('es') ?? u['gave']}',
                    style: const TextStyle(fontSize: 10.5, color: AdminColors.muted)),
              ),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton.icon(
                icon: const Icon(Icons.link, size: 16),
                label: Text(l.t('adm_asst_teach')),
                onPressed: () async {
                  final id = await _pickEntry(l, d, '${u['example']}');
                  if (id != null) {
                    await _run(() => _service.adminAssistantTeach('${u['phrase']}', id, lang: u['lang'] as String?),
                        ok: l.t('adm_asst_saved'));
                  }
                },
              ),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: Text(l.t('adm_asst_new')),
                onPressed: () => _edit(l, d, null, firstQuestion: '${u['example']}'),
              ),
              IconButton(
                tooltip: l.t('adm_asst_dismiss'),
                icon: const Icon(Icons.close, size: 18, color: AdminColors.muted),
                onPressed: () => _run(() => _service.adminAssistantDismiss('${u['phrase']}')),
              ),
            ]),
          ]),
        ),
    ];
  }

  Future<String?> _pickEntry(AppLocalizations l, _Data d, String question) {
    var q = '';
    final engine = AssistantEngine(d.kb);
    final suggested = engine.search(question).where((m) => m.entry.cat != 'smalltalk').take(3).map((m) => m.entry.id).toSet();
    return showAdminDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(builder: (c, setD) {
        final all = d.kb.entries.values.where((e) => e.cat != 'smalltalk').toList()
          ..sort((a, b) => (suggested.contains(b.id) ? 1 : 0) - (suggested.contains(a.id) ? 1 : 0));
        final list = q.isEmpty
            ? all
            : all.where((e) => '${e.id} ${e.title('es')} ${e.answer('es')}'.toLowerCase().contains(q.toLowerCase())).toList();
        return AlertDialog(
          title: Text(l.t('adm_asst_pick')),
          content: SizedBox(
            width: 480,
            height: 420,
            child: Column(children: [
              Text('«$question»', style: const TextStyle(fontSize: 12, color: AdminColors.secondary)),
              const SizedBox(height: 8),
              TextField(
                decoration: InputDecoration(isDense: true, hintText: l.t('adm_asst_search'), prefixIcon: const Icon(Icons.search, size: 17)),
                onChanged: (v) => setD(() => q = v),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: ListView(children: [
                  for (final e in list)
                    ListTile(
                      dense: true,
                      leading: suggested.contains(e.id) ? const Icon(Icons.star, size: 16, color: AdminColors.amber) : null,
                      title: Text(e.title('es'), style: const TextStyle(fontSize: 13)),
                      subtitle: Text(e.answer('es'), maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: AdminColors.muted)),
                      onTap: () => Navigator.pop(c, e.id),
                    ),
                ]),
              ),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(l.t('cancel')))],
        );
      }),
    );
  }

  // ---------- Respuestas ----------
  List<Widget> _entries(AppLocalizations l, _Data d) {
    final all = d.kb.entries.values.toList()..sort((a, b) => '${a.cat}${a.id}'.compareTo('${b.cat}${b.id}'));
    final hidden = d.remote.where((r) => r['active'] == false).map((r) => '${r['id']}').toList();
    return [
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
            icon: const Icon(Icons.add, size: 16), label: Text(l.t('adm_asst_new')), onPressed: () => _edit(l, d, null)),
      ),
      for (final e in all)
        Container(
          margin: const EdgeInsets.only(bottom: 6),
          decoration: adminCardBox(),
          child: ListTile(
            dense: true,
            title: Text(e.title('es'), style: const TextStyle(fontSize: 13, color: AdminColors.text)),
            subtitle: Text('${e.cat} · ${e.id}${e.tutorial != null ? ' · ▶' : ''}',
                style: const TextStyle(fontSize: 10.5, color: AdminColors.muted)),
            trailing: d.remoteIds.contains(e.id)
                ? AdminTag(d.seedIds.contains(e.id) ? l.t('adm_asst_custom') : l.t('adm_asst_new_tag'),
                    fg: AdminColors.amber, bg: AdminColors.amberBg)
                : null,
            onTap: () => _edit(l, d, e),
          ),
        ),
      if (hidden.isNotEmpty) ...[
        adminSectionTitle(l.t('adm_asst_hidden'), color: AdminColors.muted),
        for (final id in hidden)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            decoration: adminCardBox(),
            child: ListTile(
              dense: true,
              title: Text(id, style: const TextStyle(fontSize: 13, color: AdminColors.muted)),
              trailing: TextButton(
                onPressed: () => _run(() => _service.adminAssistantDeleteEntry(id)),
                child: Text(l.t('adm_asst_restore')),
              ),
            ),
          ),
      ],
    ];
  }

  Future<void> _edit(AppLocalizations l, _Data d, KbEntry? e, {String? firstQuestion}) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => Theme(
        data: adminDarkTheme(),
        child: _EntryEditor(
          entry: e,
          isSeed: e != null && d.seedIds.contains(e.id),
          isCustom: e != null && d.remoteIds.contains(e.id),
          firstQuestion: firstQuestion,
        ),
      ),
    ));
    if (changed == true) _reload();
  }

  // ---------- Aprendido ----------
  List<Widget> _learned(AppLocalizations l, _Data d) {
    if (d.learned.isEmpty) {
      return [Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(l.t('adm_asst_learned_none'))))];
    }
    return [
      for (final r in d.learned)
        Container(
          margin: const EdgeInsets.only(bottom: 6),
          decoration: adminCardBox(),
          child: ListTile(
            dense: true,
            title: Text('«${r['phrase']}»', style: const TextStyle(fontSize: 13, color: AdminColors.text)),
            subtitle: Text(
                '→ ${d.kb.entries['${r['entry_id']}']?.title('es') ?? r['entry_id']} · '
                '${r['source'] == 'admin' ? l.t('adm_asst_src_admin') : l.t('adm_asst_src_auto')} · ×${r['hits']}',
                style: const TextStyle(fontSize: 10.5, color: AdminColors.muted)),
            trailing: IconButton(
              tooltip: l.t('adm_asst_forget'),
              icon: const Icon(Icons.delete_outline, size: 18, color: AdminColors.red),
              onPressed: () => _run(() => _service.adminAssistantForget('${r['id']}')),
            ),
          ),
        ),
    ];
  }
}

class _Data {
  final Map<String, dynamic> seed;
  final Map<String, dynamic> summary;
  final List<Map<String, dynamic>> remote;
  final List<Map<String, dynamic>> learned;
  final AssistantKb kb;
  final Set<String> seedIds;
  final Set<String> remoteIds;
  _Data._(this.seed, this.summary, this.remote, this.learned, this.kb, this.seedIds, this.remoteIds);
  factory _Data(Map<String, dynamic> seed, Map<String, dynamic> summary, Map<String, dynamic> entries) {
    final remote = ((entries['entries'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final learned = ((entries['learned'] as List?) ?? const []).cast<Map<String, dynamic>>();
    return _Data._(
      seed, summary, remote, learned,
      AssistantKb.build(seed, {'entries': remote, 'learned': learned}),
      ((seed['entries'] as Map?) ?? const {}).keys.map((k) => '$k').toSet(),
      remote.where((r) => r['active'] != false).map((r) => '${r['id']}').toSet(),
    );
  }
}

/// Editor de una respuesta (es/ca/en). Guardar crea/sustituye la versión del
/// admin; si era de la semilla, "Restaurar original" borra la versión del admin.
class _EntryEditor extends StatefulWidget {
  final KbEntry? entry;
  final bool isSeed;
  final bool isCustom;
  final String? firstQuestion;
  const _EntryEditor({this.entry, this.isSeed = false, this.isCustom = false, this.firstQuestion});
  @override
  State<_EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<_EntryEditor> {
  final _service = DataService();
  static const _langs = ['es', 'ca', 'en'];
  late final _id = TextEditingController(text: widget.entry?.id ?? '');
  late final _cat = TextEditingController(text: widget.entry?.cat ?? 'general');
  late final _tutorial = TextEditingController(text: widget.entry?.tutorial ?? '');
  late final _action = TextEditingController(text: widget.entry?.action ?? '');
  late final _q = {
    for (final l in _langs)
      l: TextEditingController(
          text: [
            ...?widget.entry?.q[l],
            if (l == 'es' && widget.firstQuestion != null) widget.firstQuestion!,
          ].join('\n'))
  };
  late final _a = {for (final l in _langs) l: TextEditingController(text: widget.entry?.a[l] ?? '')};
  late final Set<String> _roles = {...?widget.entry?.roles};
  bool _busy = false;

  Future<void> _save({bool active = true}) async {
    final l = context.l10n;
    final id = _id.text.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9_]{2,60}$').hasMatch(id) || (active && _a['es']!.text.trim().isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('adm_asst_invalid'))));
      return;
    }
    setState(() => _busy = true);
    try {
      await _service.adminAssistantSaveEntry(
        id,
        active
            ? {
                'cat': _cat.text.trim(),
                'roles': _roles.toList(),
                'q': {for (final l in _langs) l: _q[l]!.text.split('\n').where((x) => x.trim().isNotEmpty).toList()},
                'a': {for (final l in _langs) if (_a[l]!.text.trim().isNotEmpty) l: _a[l]!.text.trim()},
                'action': _action.text.trim().isEmpty ? null : _action.text.trim(),
                'tutorial': _tutorial.text.trim().isEmpty ? null : _tutorial.text.trim(),
                'related': widget.entry?.related ?? const [],
              }
            : null,
        active: active,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _restore() async {
    setState(() => _busy = true);
    try {
      await _service.adminAssistantDeleteEntry(widget.entry!.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Widget _field(TextEditingController c, String label, {int lines = 1, bool enabled = true}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c,
          enabled: enabled,
          minLines: lines,
          maxLines: lines == 1 ? 1 : lines + 6,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(labelText: label, alignLabelWithHint: true, border: const OutlineInputBorder()),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      backgroundColor: AdminColors.bg,
      appBar: AppBar(
        backgroundColor: AdminColors.bg,
        title: Text(widget.entry == null ? l.t('adm_asst_new') : l.t('adm_asst_edit'), style: const TextStyle(fontSize: 16)),
        actions: [
          if (widget.entry != null && widget.isSeed && widget.isCustom)
            TextButton(onPressed: _busy ? null : _restore, child: Text(l.t('adm_asst_restore'))),
          if (widget.entry != null && !widget.isSeed && widget.isCustom)
            TextButton(onPressed: _busy ? null : _restore, child: Text(l.t('delete'))),
          if (widget.entry != null && widget.isSeed)
            TextButton(onPressed: _busy ? null : () => _save(active: false), child: Text(l.t('adm_asst_hide'))),
          const SizedBox(width: 4),
          FilledButton(onPressed: _busy ? null : _save, child: Text(l.t('save'))),
          const SizedBox(width: 12),
        ],
      ),
      body: adminConstrained(ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _field(_id, l.t('adm_asst_id'), enabled: widget.entry == null),
          Row(children: [
            Expanded(child: _field(_cat, l.t('adm_asst_cat'))),
            const SizedBox(width: 10),
            Expanded(child: _field(_action, l.t('adm_asst_action'))),
          ]),
          Wrap(spacing: 8, children: [
            for (final r in const ['driver', 'owner'])
              FilterChip(
                label: Text(r == 'driver' ? l.t('adm_asst_role_driver') : l.t('adm_asst_role_owner')),
                selected: _roles.contains(r),
                onSelected: (v) => setState(() => v ? _roles.add(r) : _roles.remove(r)),
              ),
          ]),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 12),
            child: Text(l.t('adm_asst_roles_help'), style: const TextStyle(fontSize: 11, color: AdminColors.muted)),
          ),
          _field(_tutorial, l.t('adm_asst_tutorial')),
          for (final lang in _langs) ...[
            adminSectionTitle(lang.toUpperCase(), color: AdminColors.amber),
            _field(_q[lang]!, l.t('adm_asst_q_hint'), lines: 3),
            _field(_a[lang]!, l.t('adm_asst_answer'), lines: 4),
          ],
        ],
      )),
    );
  }
}
