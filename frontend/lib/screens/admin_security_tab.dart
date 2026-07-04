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
          padding: const EdgeInsets.all(12),
          child: SegmentedButton<int>(
            segments: [
              ButtonSegment(value: 0, label: Text(l.t('adm_sec_alerts')), icon: const Icon(Icons.warning_amber)),
              ButtonSegment(value: 1, label: Text(l.t('adm_sec_audit')), icon: const Icon(Icons.receipt_long)),
            ],
            selected: {_view},
            onSelectionChanged: (s) { setState(() => _view = s.first); _reload(); },
          ),
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
          Wrap(spacing: 12, runSpacing: 8, children: [
            _ddown(l.t('adm_sec_severity'), _severity, {
              '': l.t('adm_ref_all'), 'low': l.t('adm_sec_low'),
              'medium': l.t('adm_sec_medium'), 'high': l.t('adm_sec_high'),
            }, (v) { setState(() => _severity = v); _reload(); }),
            _ddown(l.t('adm_sec_status'), _status, {
              '': l.t('adm_ref_all'), 'open': l.t('adm_sec_open'),
              'investigating': l.t('adm_sec_investigating'), 'resolved': l.t('adm_sec_resolved'),
            }, (v) { setState(() => _status = v); _reload(); }),
          ]),
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

  // ── Logs de auditoría ─────────────────────────────────────────────────────
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
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: [
                      DataColumn(label: Text(l.t('adm_audit_col_date'))),
                      DataColumn(label: Text(l.t('adm_audit_col_admin'))),
                      DataColumn(label: Text(l.t('adm_audit_col_action'))),
                      DataColumn(label: Text(l.t('adm_audit_col_target'))),
                      DataColumn(label: Text(l.t('adm_audit_col_details'))),
                    ],
                    rows: _logs.map((g) {
                      final created = DateTime.tryParse((g['created_at'] as String?) ?? '');
                      final admin = ((g['admin'] as Map?)?['email'] as String?) ?? '—';
                      final details = g['details'];
                      return DataRow(cells: [
                        DataCell(Text(created != null ? df.format(created) : '—')),
                        DataCell(Text(admin)),
                        DataCell(Text((g['action_type'] as String?) ?? '—')),
                        DataCell(Text('${g['target_type'] ?? ''} ${g['target_id'] ?? ''}'.trim())),
                        DataCell(SizedBox(width: 240,
                            child: Text(details == null ? '' : jsonEncode(details),
                                overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)))),
                      ]);
                    }).toList(),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _ddown(String label, String value, Map<String, String> opts, ValueChanged<String> onChanged) => SizedBox(
        width: 170,
        child: InputDecorator(
          decoration: InputDecoration(isDense: true, labelText: label, border: const OutlineInputBorder()),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value, isExpanded: true,
              items: opts.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
              onChanged: (v) => onChanged(v ?? ''),
            ),
          ),
        ),
      );
}
