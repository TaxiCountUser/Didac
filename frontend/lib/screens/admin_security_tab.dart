import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import 'admin_theme.dart';

/// Loop #5 — Pestaña "Seguridad" del Super Admin: alertas de fraude (lista
/// unificada referidos + genéricas, con resolución y notas) y logs de auditoría
/// de acciones administrativas. Solo superadmin (pantalla padre protegida).
class SecurityTab extends StatefulWidget {
  const SecurityTab({super.key});

  @override
  State<SecurityTab> createState() => _SecurityTabState();
}

class _SecurityTabState extends State<SecurityTab> {
  final _service = DataService();
  int _view = 0; // 0 = alertas, 1 = auditoría

  List<Map<String, dynamic>> _alerts = [];
  List<Map<String, dynamic>> _logs = [];
  bool _loading = true;
  String? _error;
  String _severity = '';
  String _status = '';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() { _loading = true; _error = null; });
    try {
      if (_view == 0) {
        final r = await _service.adminFraudAlerts(severity: _severity, status: _status);
        _alerts = ((r['alerts'] as List?) ?? []).cast<Map<String, dynamic>>();
      } else {
        final r = await _service.adminAuditLogs();
        _logs = ((r['logs'] as List?) ?? []).cast<Map<String, dynamic>>();
      }
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString().replaceFirst('Exception: ', ''); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: Row(children: [
            AdminPill(
                label: l.t('adm_sec_alerts'), selected: _view == 0,
                color: AdminColors.red,
                onTap: () { setState(() => _view = 0); _reload(); }),
            const SizedBox(width: 6),
            AdminPill(
                label: l.t('adm_sec_audit'), selected: _view == 1,
                color: AdminColors.gray,
                onTap: () { setState(() => _view = 1); _reload(); }),
          ]),
        ),
        Expanded(
          child: _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(16),
                  child: Text('${l.t('error')}: $_error', style: const TextStyle(color: Colors.red))))
              : _loading
                  ? const Center(child: CircularProgressIndicator())
                  : (_view == 0 ? _alertsView(l) : _auditView(l)),
        ),
      ],
    );
  }

  // ── Alertas de fraude ─────────────────────────────────────────────────────
  Widget _alertsView(AppLocalizations l) {
    final df = DateFormat('dd/MM/yyyy HH:mm');
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          SizedBox(
            height: 30,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final (v, label, c) in [
                ('', l.t('adm_ref_all'), AdminColors.red),
                ('high', l.t('adm_sec_high'), AdminColors.red),
                ('medium', l.t('adm_sec_medium'), AdminColors.amber),
                ('low', l.t('adm_sec_low'), AdminColors.gray),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: AdminPill(label: label, selected: _severity == v, color: c,
                      onTap: () { setState(() => _severity = v); _reload(); }),
                ),
            ]),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 30,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final (v, label, c) in [
                ('', l.t('adm_ref_all'), AdminColors.amber),
                ('open', l.t('adm_sec_open'), AdminColors.amber),
                ('investigating', l.t('adm_sec_investigating'), AdminColors.blue),
                ('resolved', l.t('adm_sec_resolved'), AdminColors.teal),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: AdminPill(label: label, selected: _status == v, color: c,
                      onTap: () { setState(() => _status = v); _reload(); }),
                ),
            ]),
          ),
          const SizedBox(height: 8),
          if (_alerts.isEmpty)
            Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(l.t('adm_sec_none'))))
          else
            for (final a in _alerts) _alertTile(l, a, df),
        ],
      ),
    );
  }

  Widget _alertTile(AppLocalizations l, Map<String, dynamic> a, DateFormat df) {
    final severity = (a['severity'] as String?) ?? 'medium';
    final status = (a['status'] as String?) ?? 'open';
    final type = (a['alert_type'] as String?) ?? '—';
    final source = (a['source'] as String?) ?? '';
    final created = DateTime.tryParse((a['created_at'] as String?) ?? '');
    final sevColor = switch (severity) {
      'high' => AdminColors.red, 'medium' => AdminColors.amber, _ => AdminColors.gray,
    };
    final resolved = status == 'resolved';
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: adminCardBox(
          borderColor: severity == 'high' && !resolved ? AdminColors.red : null),
      child: ListTile(
        onTap: () => _openAlert(l, a),
        leading: Icon(Icons.flag, color: sevColor),
        title: Text('$type · ${l.t('adm_sec_$severity')}',
            style: const TextStyle(fontSize: 13)),
        subtitle: Text('${l.t('adm_sec_src_$source')} · '
            '${created != null ? df.format(created) : ''}',
            style: const TextStyle(fontSize: 11, color: AdminColors.muted)),
        trailing: AdminTag(l.t('adm_sec_$status'),
            fg: resolved ? AdminColors.teal : AdminColors.amber,
            bg: resolved ? AdminColors.tealBg : AdminColors.amberBg),
      ),
    );
  }

  Future<void> _openAlert(AppLocalizations l, Map<String, dynamic> a) async {
    final notesCtrl = TextEditingController();
    final evidence = a['evidence'];
    final status = (a['status'] as String?) ?? 'open';
    final resolved = status == 'resolved';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${a['alert_type']}'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('${l.t('adm_sec_severity')}: ${l.t('adm_sec_${a['severity'] ?? 'medium'}')}'),
              Text('${l.t('adm_sec_status')}: ${l.t('adm_sec_$status')}'),
              if (a['description'] != null) ...[const SizedBox(height: 6), Text('${a['description']}')],
              const Divider(),
              Text(l.t('adm_sec_evidence'), style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(evidence == null ? '—' : const JsonEncoder.withIndent('  ').convert(evidence),
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
              if (a['resolution_notes'] != null) ...[
                const SizedBox(height: 6),
                Text('${l.t('adm_sec_notes')}: ${a['resolution_notes']}', style: const TextStyle(fontSize: 12)),
              ],
              if (!resolved) ...[
                const Divider(),
                TextField(controller: notesCtrl,
                    decoration: InputDecoration(labelText: l.t('adm_sec_notes'), border: const OutlineInputBorder())),
              ],
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.t('close'))),
          if (!resolved)
            FilledButton(
              onPressed: () async {
                Navigator.pop(ctx);
                try {
                  await _service.adminFraudResolve(a['alert_id'] as String, notesCtrl.text.trim());
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('adm_sec_resolved_ok'))));
                  _reload();
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
                }
              },
              child: Text(l.t('adm_sec_resolve')),
            ),
        ],
      ),
    );
  }

  // ── Logs de auditoría (rediseño N: filas oscuras, legible en móvil) ────────
  Widget _auditView(AppLocalizations l) {
    final df = DateFormat('dd/MM/yyyy HH:mm');
    return RefreshIndicator(
      onRefresh: _reload,
      child: _logs.isEmpty
          ? ListView(children: [Padding(padding: const EdgeInsets.all(24),
              child: Center(child: Text(l.t('adm_audit_none'))))])
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Container(
                  decoration: adminCardBox(),
                  child: Column(children: [
                    for (var i = 0; i < _logs.length; i++) ...[
                      if (i > 0)
                        const Divider(height: 1, color: AdminColors.hairline),
                      _auditRow(l, _logs[i], df),
                    ],
                  ]),
                ),
              ],
            ),
    );
  }

  Widget _auditRow(AppLocalizations l, Map<String, dynamic> g, DateFormat df) {
    final created = DateTime.tryParse((g['created_at'] as String?) ?? '');
    final admin = ((g['admin'] as Map?)?['email'] as String?) ?? '—';
    final details = g['details'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdminTag((g['action_type'] as String?) ?? '—',
              fg: AdminColors.gray, bg: AdminColors.hairline),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${g['target_type'] ?? ''} ${g['target_id'] ?? ''}'.trim(),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: AdminColors.text)),
                Text('$admin · ${created != null ? df.format(created) : '—'}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: AdminColors.muted)),
                if (details != null)
                  Text(jsonEncode(details),
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 10, color: AdminColors.secondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
