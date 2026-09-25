import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import 'admin_theme.dart';

/// Pestaña "Parseig" de Monitorización: dónde corrige la gente lo que entendió
/// el parseo por voz (tabla parse_feedback, mig. 086). Cada corrección viene
/// clasificada por el backend:
///   kind : missing (no detectado) | wrong (mal) | extra (sobraba)
///   stage: merge (el parser o la IA lo tenían y la mezcla no) | interpretation
///          (el texto lo decía y nadie lo sacó) | transcription (Whisper lo oyó mal)
/// Se refresca sola cada 30 s.
class ParseFeedbackView extends StatefulWidget {
  const ParseFeedbackView({super.key});

  @override
  State<ParseFeedbackView> createState() => _ParseFeedbackViewState();
}

const _fields = [
  'type', 'amount', 'payment_method', 'category', 'origin', 'destination', 'client_name', 'odometer_km',
];

Color _stageColor(String? s) => switch (s) {
      'merge' => AdminColors.amber,
      'transcription' => AdminColors.coral,
      _ => AdminColors.purple,
    };
Color _stageBg(String? s) => switch (s) {
      'merge' => AdminColors.amberBg,
      'transcription' => AdminColors.coralBg,
      _ => AdminColors.purpleBg,
    };

class _ParseFeedbackViewState extends State<ParseFeedbackView> {
  final _service = DataService();
  int _days = 7;
  String _only = 'corrected';
  Map<String, dynamic> _summary = {};
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;
  DateTime? _updated;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() { _loading = true; _error = null; });
    try {
      final r = await Future.wait([
        _service.adminParseSummary(days: _days),
        _service.adminParseFeedback(only: _only),
      ]);
      if (!mounted) return;
      setState(() {
        _summary = r[0] as Map<String, dynamic>;
        _items = r[1] as List<Map<String, dynamic>>;
        _loading = false;
        _error = null;
        _updated = DateTime.now();
      });
    } catch (e) {
      if (!mounted || silent) return;
      setState(() { _error = e.toString().replaceFirst('Exception: ', ''); _loading = false; });
    }
  }

  int _n(String k) => (_summary[k] as num?)?.toInt() ?? 0;
  String _pct(int a, int b) => b == 0 ? '—' : '${((a * 100) / b).round()}%';

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(16),
          child: Text('${l.t('error')}: $_error', style: const TextStyle(color: Colors.red))));
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 4),
            child: Text(l.t('adm_parse_intro'),
                style: const TextStyle(fontSize: 11, color: AdminColors.muted)),
          ),
          Row(children: [
            for (final d in const [7, 30]) ...[
              AdminPill(
                  label: l.t('adm_parse_days', {'n': '$d'}), selected: _days == d,
                  color: AdminColors.teal,
                  onTap: () { setState(() => _days = d); _load(); }),
              const SizedBox(width: 6),
            ],
            const Spacer(),
            if (_updated != null)
              Text(l.t('adm_parse_auto', {'t': DateFormat('HH:mm:ss').format(_updated!)}),
                  style: const TextStyle(fontSize: 10, color: AdminColors.muted)),
          ]),
          const SizedBox(height: 10),
          _kpis(l),
          adminSectionTitle(l.t('adm_parse_sec_fields'), color: AdminColors.purple),
          _fieldsCard(l),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
            child: Text(l.t('adm_parse_legend'),
                style: const TextStyle(fontSize: 10, color: AdminColors.muted)),
          ),
          adminSectionTitle(l.t('adm_parse_sec_recent'), color: AdminColors.blue),
          Row(children: [
            for (final o in const ['corrected', 'abandoned', 'all']) ...[
              AdminPill(
                  label: l.t('adm_parse_only_$o'), selected: _only == o,
                  color: AdminColors.blue,
                  onTap: () { setState(() => _only = o); _load(); }),
              const SizedBox(width: 6),
            ],
          ]),
          const SizedBox(height: 8),
          if (_items.isEmpty)
            adminRowsCard([Padding(padding: const EdgeInsets.all(14),
                child: Text(l.t('adm_parse_none_items'),
                    style: const TextStyle(fontSize: 12, color: AdminColors.muted)))])
          else
            adminRowsCard([for (final it in _items) _itemRow(l, it)]),
        ],
      ),
    );
  }

  Widget _kpis(AppLocalizations l) {
    final total = _n('total');
    final saved = _n('saved');
    final llmUsed = _n('llm_used');
    final ms = (_summary['llm_avg_ms'] as num?)?.toInt();
    final tiles = [
      AdminKpiTile(label: l.t('adm_parse_k_total'), value: '$total',
          sub: l.t('adm_parse_k_total_sub', {'n': '$saved'}), color: AdminColors.blue, icon: Icons.mic),
      AdminKpiTile(label: l.t('adm_parse_k_clean'), value: _pct(_n('clean'), saved),
          sub: l.t('adm_parse_k_clean_sub', {'n': '${_n('clean')}'}), color: AdminColors.teal,
          icon: Icons.check_circle_outline),
      AdminKpiTile(label: l.t('adm_parse_k_abandoned'), value: '${_n('abandoned')}',
          sub: _pct(_n('abandoned'), total), color: AdminColors.coral, icon: Icons.close),
      AdminKpiTile(label: l.t('adm_parse_k_llm'), value: _pct(llmUsed, total),
          sub: l.t('adm_parse_k_llm_sub', {'n': '$llmUsed'}), color: AdminColors.purple,
          icon: Icons.auto_awesome),
      AdminKpiTile(label: l.t('adm_parse_k_llm_err'), value: '${_n('llm_errors')}',
          sub: _pct(_n('llm_errors'), llmUsed),
          color: _n('llm_errors') > 0 ? AdminColors.red : AdminColors.gray, icon: Icons.error_outline),
      AdminKpiTile(label: l.t('adm_parse_k_llm_ms'), value: ms == null ? '—' : '${(ms / 1000).toStringAsFixed(1)} s',
          color: AdminColors.gray, icon: Icons.timer_outlined),
    ];
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth >= 900 ? 6 : c.maxWidth >= 520 ? 3 : 2;
      final w = (c.maxWidth - (cols - 1) * 8) / cols;
      return Wrap(spacing: 8, runSpacing: 8, children: [
        for (final t in tiles)
          AdminKpiTile(label: t.label, value: t.value, sub: t.sub, color: t.color, icon: t.icon, width: w),
      ]);
    });
  }

  Widget _fieldsCard(AppLocalizations l) {
    final fields = (_summary['fields'] as Map?)?.cast<String, dynamic>() ?? {};
    final saved = _n('saved');
    if (saved == 0) {
      return adminRowsCard([Padding(padding: const EdgeInsets.all(14),
          child: Text(l.t('adm_parse_none'), style: const TextStyle(fontSize: 12, color: AdminColors.muted)))]);
    }
    final rows = <Widget>[];
    // Los campos con más correcciones primero.
    final sorted = [..._fields]..sort((a, b) =>
        ((fields[b]?['corrected'] as num?) ?? 0).compareTo((fields[a]?['corrected'] as num?) ?? 0));
    for (final f in sorted) {
      final s = (fields[f] as Map?)?.cast<String, dynamic>() ?? {};
      final c = (s['corrected'] as num?)?.toInt() ?? 0;
      final pct = saved == 0 ? 0.0 : c / saved;
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(l.t('adm_parse_f_$f'),
                style: const TextStyle(fontSize: 13, color: AdminColors.text))),
            Text(c == 0 ? l.t('adm_parse_f_ok') : '$c · ${_pct(c, saved)}',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                    color: c == 0 ? AdminColors.teal : AdminColors.text)),
          ]),
          if (c > 0) ...[
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: pct.clamp(0, 1).toDouble(), minHeight: 4,
                backgroundColor: AdminColors.hairline,
                color: pct > .2 ? AdminColors.red : pct > .08 ? AdminColors.amber : AdminColors.teal,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(spacing: 5, runSpacing: 4, children: [
              for (final st in const ['merge', 'interpretation', 'transcription'])
                if (((s[st] as num?) ?? 0) > 0)
                  AdminTag('${l.t('adm_parse_stage_$st')} ${s[st]}', fg: _stageColor(st), bg: _stageBg(st)),
              for (final k in const ['missing', 'wrong', 'extra'])
                if (((s[k] as num?) ?? 0) > 0)
                  AdminTag('${l.t('adm_parse_kind_$k')} ${s[k]}', fg: AdminColors.gray, bg: AdminColors.hairline),
            ]),
          ],
        ]),
      ));
    }
    return adminRowsCard(rows);
  }

  String _val(AppLocalizations l, String f, dynamic v) {
    if (v == null || v == '' || (f == 'amount' && v == 0)) return '—';
    if (f == 'type') return v == 'expense' ? l.t('adm_parse_expense') : l.t('adm_parse_income');
    if (f == 'amount') return '${v is num ? v.toStringAsFixed(2) : v} €';
    return '$v';
  }

  Widget _itemRow(AppLocalizations l, Map<String, dynamic> it) {
    final corr = (it['corrections'] as Map?)?.cast<String, dynamic>() ?? {};
    final at = DateTime.tryParse('${it['created_at']}')?.toLocal();
    final tenant = (it['tenant'] as Map?)?['name'] as String?;
    return InkWell(
      onTap: () => _detail(l, it),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('«${it['text'] ?? ''}»', maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: AdminColors.text)),
            ),
            const Icon(Icons.chevron_right, size: 16, color: AdminColors.muted),
          ]),
          const SizedBox(height: 3),
          Text([
            if (at != null) DateFormat('dd/MM HH:mm').format(at),
            if (tenant != null) tenant,
            if (it['status'] == 'pending') l.t('adm_parse_abandoned'),
            if (it['llm_skipped'] == true) l.t('adm_parse_llm_skipped'),
            if (it['llm_error'] != null) l.t('adm_parse_llm_failed'),
          ].join(' · '), style: const TextStyle(fontSize: 10.5, color: AdminColors.muted)),
          if (corr.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final e in corr.entries)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(children: [
                  AdminTag(l.t('adm_parse_stage_${e.value['stage']}'),
                      fg: _stageColor(e.value['stage'] as String?), bg: _stageBg(e.value['stage'] as String?)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${l.t('adm_parse_f_${e.key}')}: ${_val(l, e.key, e.value['proposed'])} → ${_val(l, e.key, e.value['saved'])}',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: AdminColors.secondary)),
                  ),
                ]),
              ),
          ],
        ]),
      ),
    );
  }

  void _detail(AppLocalizations l, Map<String, dynamic> it) {
    final det = (it['det'] as Map?)?.cast<String, dynamic>() ?? {};
    final llm = (it['llm'] as Map?)?.cast<String, dynamic>();
    final prop = (it['proposed'] as Map?)?.cast<String, dynamic>() ?? {};
    final saved = (it['saved'] as Map?)?.cast<String, dynamic>();
    final corr = (it['corrections'] as Map?)?.cast<String, dynamic>() ?? {};
    const head = TextStyle(fontSize: 10, color: AdminColors.muted, fontWeight: FontWeight.w600);
    Widget cell(String s, {Color? color, bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
          child: Text(s, style: TextStyle(fontSize: 11.5, color: color ?? AdminColors.text,
              fontWeight: bold ? FontWeight.w600 : FontWeight.w400)),
        );
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('adm_parse_detail'), style: const TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 620,
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.t('adm_parse_whisper'), style: head),
              const SizedBox(height: 2),
              Text('«${it['raw_text'] ?? it['text'] ?? ''}»',
                  style: const TextStyle(fontSize: 13, color: AdminColors.text)),
              if (it['raw_text'] != null && it['raw_text'] != it['text']) ...[
                const SizedBox(height: 6),
                Text(l.t('adm_parse_corrected_text'), style: head),
                Text('«${it['text']}»', style: const TextStyle(fontSize: 13, color: AdminColors.secondary)),
              ],
              if (it['llm_error'] != null) ...[
                const SizedBox(height: 6),
                Text('${l.t('adm_parse_llm_failed')}: ${it['llm_error']}',
                    style: const TextStyle(fontSize: 11, color: AdminColors.red)),
              ],
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Table(
                  defaultColumnWidth: const IntrinsicColumnWidth(),
                  border: const TableBorder(horizontalInside: BorderSide(color: AdminColors.hairline)),
                  children: [
                    TableRow(children: [
                      cell('', color: AdminColors.muted),
                      cell(l.t('adm_parse_col_det'), color: AdminColors.muted),
                      cell(l.t('adm_parse_col_llm'), color: AdminColors.muted),
                      cell(l.t('adm_parse_col_proposed'), color: AdminColors.muted),
                      cell(l.t('adm_parse_col_saved'), color: AdminColors.muted),
                    ]),
                    for (final f in _fields)
                      TableRow(children: [
                        cell(l.t('adm_parse_f_$f'), color: AdminColors.secondary),
                        cell(_val(l, f, det[f])),
                        cell(llm == null ? (it['llm_skipped'] == true ? '·' : '—') : _val(l, f, llm[f])),
                        cell(_val(l, f, prop[f])),
                        cell(saved == null ? '' : _val(l, f, saved[f]),
                            color: corr.containsKey(f) ? _stageColor(corr[f]['stage'] as String?) : null,
                            bold: corr.containsKey(f)),
                      ]),
                  ],
                ),
              ),
              if (it['llm_skipped'] == true) ...[
                const SizedBox(height: 8),
                Text(l.t('adm_parse_llm_skipped_note'),
                    style: const TextStyle(fontSize: 10.5, color: AdminColors.muted)),
              ],
            ]),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.t('close')))],
      ),
    );
  }
}
