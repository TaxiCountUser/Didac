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
  int _view = 0; // 0 = alertas, 1 = auditoría, 2 = semáforos

  List<Map<String, dynamic>> _alerts = [];
  List<Map<String, dynamic>> _logs = [];
  List<Map<String, dynamic>> _semaphores = [];
  bool _loading = true;
  String? _error;
  String _severity = '';
  String _status = '';
  String _actionFilter = ''; // auditoría: filtro por tipo de acción

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
      } else if (_view == 1) {
        final r = await _service.adminAuditLogs();
        _logs = ((r['logs'] as List?) ?? []).cast<Map<String, dynamic>>();
      } else {
        _semaphores = await _service.adminSemaphores();
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
            const SizedBox(width: 6),
            AdminPill(
                label: l.t('adm_sec_sema'), selected: _view == 2,
                color: AdminColors.teal,
                onTap: () { setState(() => _view = 2); _reload(); }),
          ]),
        ),
        Expanded(
          child: _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(16),
                  child: Text('${l.t('error')}: $_error', style: const TextStyle(color: Colors.red))))
              : _loading
                  ? const Center(child: CircularProgressIndicator())
                  : (_view == 0
                      ? _alertsView(l)
                      : _view == 1
                          ? _auditView(l)
                          : _semaphoresView(l)),
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
    await showAdminDialog<void>(
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

  // ── Logs de auditoría (rediseño N: filtro por tipo de acción + detalle) ────
  // Color por familia de acción, para distinguir de un vistazo qué pasó.
  Color _actionColor(String a) {
    if (a.startsWith('challenge')) return AdminColors.amber;
    if (a.startsWith('referral')) return AdminColors.pink;
    if (a.startsWith('fraud')) return AdminColors.red;
    if (a.startsWith('company')) return AdminColors.purple;
    if (a.startsWith('error_report')) return AdminColors.coral;
    if (a.startsWith('purge')) return AdminColors.blue;
    return AdminColors.gray;
  }

  Widget _auditView(AppLocalizations l) {
    final df = DateFormat('dd/MM/yyyy HH:mm');
    // Tipos de acción presentes en los logs cargados (dinámico).
    final types = _logs
        .map((g) => (g['action_type'] as String?) ?? '')
        .where((t) => t.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final visible = _actionFilter.isEmpty
        ? _logs
        : _logs.where((g) => g['action_type'] == _actionFilter).toList();
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (types.length > 1)
            SizedBox(
              height: 30,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: AdminPill(
                      label: l.t('adm_ref_all'),
                      selected: _actionFilter.isEmpty,
                      color: AdminColors.gray,
                      onTap: () => setState(() => _actionFilter = '')),
                ),
                for (final t in types)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: AdminPill(
                        label: _actionLabel(l, t), selected: _actionFilter == t,
                        color: _actionColor(t),
                        onTap: () => setState(() => _actionFilter = t)),
                  ),
              ]),
            ),
          const SizedBox(height: 8),
          if (visible.isEmpty)
            Padding(padding: const EdgeInsets.all(24),
                child: Center(child: Text(l.t('adm_audit_none'))))
          else
            Container(
              decoration: adminCardBox(),
              child: Column(children: [
                for (var i = 0; i < visible.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, color: AdminColors.hairline),
                  _auditRow(l, visible[i], df),
                ],
              ]),
            ),
        ],
      ),
    );
  }

  // ── Semáforos: log del estado de crons + servicios externos + API ─────────
  // Etiqueta legible de cada semáforo por su clave.
  String _semaLabel(AppLocalizations l, String key) => switch (key) {
        'api' => 'API',
        'challenge_credits' => l.t('adm_sema_credits'),
        'referral_validations' => l.t('adm_sema_referrals'),
        'backup' => l.t('adm_sema_backup'),
        'whisper' => 'Whisper',
        'openai' => 'OpenAI',
        _ => key,
      };

  // Color por estado: ok/live verde, stale/error rojo, never gris.
  Color _semaColor(String status) => switch (status) {
        'ok' || 'live' => AdminColors.teal,
        'stale' || 'error' => AdminColors.red,
        _ => AdminColors.gray,
      };

  Widget _semaphoresView(AppLocalizations l) {
    final df = DateFormat('dd/MM/yyyy HH:mm');
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 4),
            child: Text(l.t('adm_sema_intro'),
                style: const TextStyle(fontSize: 11, color: AdminColors.muted)),
          ),
          if (_semaphores.isEmpty)
            Padding(padding: const EdgeInsets.all(24),
                child: Center(child: Text(l.t('adm_audit_none'))))
          else
            Container(
              decoration: adminCardBox(),
              child: Column(children: [
                for (var i = 0; i < _semaphores.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, color: AdminColors.hairline),
                  _semaRow(l, _semaphores[i], df),
                ],
              ]),
            ),
        ],
      ),
    );
  }

  Widget _semaRow(AppLocalizations l, Map<String, dynamic> s, DateFormat df) {
    final key = (s['key'] as String?) ?? '—';
    final status = (s['status'] as String?) ?? 'never';
    final at = DateTime.tryParse((s['at'] as String?) ?? '');
    final color = _semaColor(status);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      child: Row(
        children: [
          Container(
              width: 9, height: 9,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_semaLabel(l, key),
                    style: const TextStyle(fontSize: 13, color: AdminColors.text)),
                Text(
                  at != null
                      ? l.t('adm_sema_last', {'d': df.format(at)})
                      : l.t('adm_sema_nodata'),
                  style: const TextStyle(fontSize: 10.5, color: AdminColors.muted),
                ),
              ],
            ),
          ),
          AdminTag(l.t('adm_sema_st_$status'),
              fg: color, bg: color.withValues(alpha: .16)),
        ],
      ),
    );
  }

  // Etiqueta legible de la acción (aud_<action>), con fallback al código crudo.
  String _actionLabel(AppLocalizations l, String action) {
    final s = l.t('aud_$action');
    return s == 'aud_$action' ? action : s;
  }

  Widget _auditRow(AppLocalizations l, Map<String, dynamic> g, DateFormat df) {
    final created = DateTime.tryParse((g['created_at'] as String?) ?? '');
    final admin = ((g['admin'] as Map?)?['email'] as String?) ?? '—';
    final details = g['details'];
    final action = (g['action_type'] as String?) ?? '—';
    final color = _actionColor(action);
    return InkWell(
      onTap: () => _openAuditDetail(l, g, df),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AdminTag(_actionLabel(l, action), fg: color, bg: color.withValues(alpha: .16)),
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
            const Icon(Icons.chevron_right, size: 14, color: AdminColors.muted),
          ],
        ),
      ),
    );
  }

  // Detalle completo de una acción de auditoría (JSON legible).
  Future<void> _openAuditDetail(
      AppLocalizations l, Map<String, dynamic> g, DateFormat df) async {
    final created = DateTime.tryParse((g['created_at'] as String?) ?? '');
    final admin = ((g['admin'] as Map?)?['email'] as String?) ?? '—';
    final details = g['details'];
    final pretty = details == null
        ? '—'
        : const JsonEncoder.withIndent('  ').convert(details);
    await showAdminDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_actionLabel(l, (g['action_type'] as String?) ?? '—'),
            style: const TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$admin · ${created != null ? df.format(created) : '—'}',
                    style: const TextStyle(
                        fontSize: 12, color: AdminColors.muted)),
                const SizedBox(height: 4),
                Text('${g['target_type'] ?? ''} ${g['target_id'] ?? ''}'.trim(),
                    style: const TextStyle(fontSize: 12)),
                const Divider(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AdminColors.bg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(pretty,
                      style: const TextStyle(
                          fontSize: 11, fontFamily: 'monospace',
                          color: AdminColors.secondary)),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(l.t('close'))),
        ],
      ),
    );
  }
}
