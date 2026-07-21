import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import 'admin_theme.dart';

/// Rediseño del panel admin: la antigua "Seguridad" se dividió en tarjetas
/// separadas. Este widget sirve DOS de ellas según `mode`:
///   - 'monitoring' → Métricas (en vivo) + Semáforos + Flags de plataforma.
///   - 'audit'      → log de auditoría de acciones administrativas.
/// (Las alertas de fraude se movieron a la tarjeta de Referidos.)
class SecurityTab extends StatefulWidget {
  final String mode; // 'monitoring' | 'audit'
  const SecurityTab({super.key, this.mode = 'monitoring'});

  @override
  State<SecurityTab> createState() => _SecurityTabState();
}

class _SecurityTabState extends State<SecurityTab> {
  final _service = DataService();
  // Vistas: 1 = auditoría, 2 = semáforos, 3 = métricas (números heredados).
  late int _view = widget.mode == 'audit' ? 1 : 3;

  List<Map<String, dynamic>> _logs = [];
  List<Map<String, dynamic>> _semaphores = [];
  Map<String, dynamic> _flags = {};
  Map<String, dynamic> _metrics = {};
  String? _flagBusy; // nombre del flag conmutándose (deshabilita el switch)
  bool _loading = true;
  String? _error;
  String _actionFilter = ''; // auditoría: filtro por tipo de acción (servidor)
  String _adminFilter = ''; // auditoría: filtro por admin (id)
  String _adminFilterLabel = ''; // email del admin filtrado (para el chip)
  DateTime? _from; // auditoría: rango de fechas
  DateTime? _to;
  int _auditOffset = 0;
  final int _auditPageSize = 50;
  int _auditTotal = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() { _loading = true; _error = null; });
    try {
      if (_view == 1) {
        final r = await _service.adminAuditLogs(
          actionType: _actionFilter,
          adminId: _adminFilter,
          from: _from?.toUtc().toIso8601String(),
          // "hasta" inclusivo: hasta el final de ese día.
          to: _to?.add(const Duration(days: 1)).toUtc().toIso8601String(),
          limit: _auditPageSize,
          offset: _auditOffset,
        );
        _logs = ((r['logs'] as List?) ?? []).cast<Map<String, dynamic>>();
        _auditTotal = (r['total'] as num?)?.toInt() ?? _logs.length;
      } else if (_view == 2) {
        _semaphores = await _service.adminSemaphores();
        _flags = await _service.adminFlags();
      } else {
        _metrics = await _service.adminMetrics();
      }
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString().replaceFirst('Exception: ', ''); _loading = false; });
    }
  }

  Future<void> _toggleFlag(String name, bool on) async {
    setState(() => _flagBusy = name);
    try {
      await _service.adminSetFlag(name, on);
      final f = Map<String, dynamic>.from((_flags[name] as Map?) ?? {});
      f['on'] = on;
      _flags = {..._flags, name: f};
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    } finally {
      if (mounted) setState(() => _flagBusy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final monitoring = widget.mode != 'audit';
    return Column(
      children: [
        if (monitoring)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: Row(children: [
              AdminPill(
                  label: l.t('adm_metrics'), selected: _view == 3,
                  color: AdminColors.blue,
                  onTap: () { setState(() => _view = 3); _reload(); }),
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
                  : (_view == 1
                      ? _auditView(l)
                      : _view == 2
                          ? _semaphoresView(l)
                          : _metricsView(l)),
        ),
      ],
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

  // Recarga la auditoría desde el principio (al cambiar cualquier filtro).
  void _auditReload() { _auditOffset = 0; _reload(); }

  Future<void> _pickAuditDate(bool isFrom) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: (isFrom ? _from : _to) ?? now,
      firstDate: DateTime(2024),
      lastDate: now,
    );
    if (picked == null) return;
    setState(() { if (isFrom) { _from = picked; } else { _to = picked; } });
    _auditReload();
  }

  Widget _auditView(AppLocalizations l) {
    final df = DateFormat('dd/MM/yyyy HH:mm');
    final dfd = DateFormat('dd/MM/yy');
    // Tipos de acción presentes en la página cargada (para las píldoras).
    final types = _logs
        .map((g) => (g['action_type'] as String?) ?? '')
        .where((t) => t.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // Rango de fechas + exportar CSV.
          Row(children: [
            Expanded(
              child: _dateChip(l, l.t('adm_audit_from'),
                  _from == null ? null : dfd.format(_from!),
                  () => _pickAuditDate(true)),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _dateChip(l, l.t('adm_audit_to'),
                  _to == null ? null : dfd.format(_to!),
                  () => _pickAuditDate(false)),
            ),
            IconButton(
              tooltip: l.t('adm_ref_export_csv'),
              icon: const Icon(Icons.download, size: 19, color: AdminColors.secondary),
              onPressed: _logs.isEmpty ? null : _exportAuditCsv,
            ),
          ]),
          // Chip de filtro por admin activo.
          if (_adminFilter.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: InputChip(
                  label: Text(_adminFilterLabel, style: const TextStyle(fontSize: 11)),
                  avatar: const Icon(Icons.person, size: 14),
                  onDeleted: () {
                    setState(() { _adminFilter = ''; _adminFilterLabel = ''; });
                    _auditReload();
                  },
                ),
              ),
            ),
          const SizedBox(height: 8),
          if (types.length > 1 || _actionFilter.isNotEmpty)
            SizedBox(
              height: 30,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: AdminPill(
                      label: l.t('adm_ref_all'),
                      selected: _actionFilter.isEmpty,
                      color: AdminColors.gray,
                      onTap: () { setState(() => _actionFilter = ''); _auditReload(); }),
                ),
                for (final t in types)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: AdminPill(
                        label: _actionLabel(l, t), selected: _actionFilter == t,
                        color: _actionColor(t),
                        onTap: () { setState(() => _actionFilter = t); _auditReload(); }),
                  ),
              ]),
            ),
          const SizedBox(height: 8),
          if (_logs.isEmpty)
            Padding(padding: const EdgeInsets.all(24),
                child: Center(child: Text(l.t('adm_audit_none'))))
          else ...[
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
            const SizedBox(height: 10),
            _auditPagination(l),
          ],
        ],
      ),
    );
  }

  Widget _dateChip(AppLocalizations l, String label, String? value, VoidCallback onTap) =>
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: value == null ? AdminColors.secondary : AdminColors.text,
          side: const BorderSide(color: AdminColors.hairline),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 10),
        ),
        icon: const Icon(Icons.event, size: 15),
        label: Text(value ?? label,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11)),
        onPressed: onTap,
      );

  Widget _auditPagination(AppLocalizations l) {
    final from = _auditTotal == 0 ? 0 : _auditOffset + 1;
    final to = (_auditOffset + _auditPageSize).clamp(0, _auditTotal);
    return Row(children: [
      Text(l.t('adm_ref_page', {'from': '$from', 'to': '$to', 'total': '$_auditTotal'}),
          style: const TextStyle(fontSize: 11, color: AdminColors.secondary)),
      const Spacer(),
      IconButton(
        onPressed: _auditOffset > 0
            ? () { setState(() => _auditOffset -= _auditPageSize); _reload(); }
            : null,
        icon: const Icon(Icons.chevron_left),
      ),
      IconButton(
        onPressed: (_auditOffset + _auditPageSize) < _auditTotal
            ? () { setState(() => _auditOffset += _auditPageSize); _reload(); }
            : null,
        icon: const Icon(Icons.chevron_right),
      ),
    ]);
  }

  // Exporta al portapapeles la página cargada (compatible web + móvil).
  void _exportAuditCsv() {
    final l = context.l10n;
    final buf = StringBuffer('fecha,admin,accion,objetivo,ip,detalles\n');
    for (final g in _logs) {
      String q(String s) => '"${s.replaceAll('"', '""')}"';
      final admin = ((g['admin'] as Map?)?['email'] as String?) ?? '';
      final target = '${g['target_type'] ?? ''} ${g['target_id'] ?? ''}'.trim();
      final det = g['details'] == null ? '' : jsonEncode(g['details']);
      buf.writeln([
        q('${g['created_at'] ?? ''}'), q(admin), q('${g['action_type'] ?? ''}'),
        q(target), q('${g['ip_address'] ?? ''}'), q(det),
      ].join(','));
    }
    Clipboard.setData(ClipboardData(text: buf.toString()));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l.t('adm_ref_csv_copied'))));
  }

  // ── Semáforos: log del estado de crons + servicios externos + API ─────────
  // Etiqueta legible de cada semáforo por su clave.
  String _semaLabel(AppLocalizations l, String key) => switch (key) {
        'api' => 'API',
        'database' => l.t('adm_sema_db'),
        'challenge_credits' => l.t('adm_sema_credits'),
        'referral_validations' => l.t('adm_sema_referrals'),
        'backup' => l.t('adm_sema_backup'),
        'purge_retention' => l.t('adm_sema_purge'),
        'stripe' => 'Stripe',
        'whisper' => 'Whisper',
        'openai' => 'OpenAI',
        'push' => l.t('adm_sema_push'),
        'webhook_errors' => l.t('adm_sema_webhooks'),
        'groq' => l.t('adm_sema_groq'),
        'supabase_res' => l.t('adm_sema_supares'),
        _ => key,
      };

  // Color por estado: ok/live verde, slow ámbar, stale/error/dead rojo,
  // never/off gris (sin datos / apagado a propósito).
  Color _semaColor(String status) => switch (status) {
        'ok' || 'live' => AdminColors.teal,
        'slow' => AdminColors.amber,
        'stale' || 'error' || 'dead' => AdminColors.red,
        _ => AdminColors.gray,
      };

  // Gravedad para ordenar "peor primero": problemas > avisos > desconocido > ok.
  int _semaRank(String? s) => switch (s) {
        'stale' || 'error' || 'dead' => 0,
        'slow' => 1,
        'ok' || 'live' => 3,
        _ => 2,
      };

  // Resumen tipo status page: "todos operativos" o "N con problemas · M avisos".
  Widget _statusSummary(AppLocalizations l) {
    var problems = 0, warns = 0;
    for (final s in _semaphores) {
      final r = _semaRank(s['status'] as String?);
      if (r == 0) {
        problems++;
      } else if (r == 1) {
        warns++;
      }
    }
    final ok = problems == 0 && warns == 0;
    final color = problems > 0
        ? AdminColors.red
        : (warns > 0 ? AdminColors.amber : AdminColors.teal);
    final text = ok
        ? l.t('adm_sema_all_ok')
        : [
            if (problems > 0) l.t('adm_sema_problems', {'n': '$problems'}),
            if (warns > 0) l.t('adm_sema_warns', {'n': '$warns'}),
          ].join(' · ');
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        border: Border.all(color: color.withValues(alpha: .5)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(ok ? Icons.check_circle : Icons.error_outline, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: color)),
        ),
        Text('${_semaphores.length}',
            style: const TextStyle(fontSize: 11, color: AdminColors.muted)),
      ]),
    );
  }

  Widget _semaphoresView(AppLocalizations l) {
    final df = DateFormat('dd/MM/yyyy HH:mm');
    // Peor primero: lo que falla, arriba (status pages son "incident-first").
    final sorted = [..._semaphores]..sort((a, b) => _semaRank(a['status'] as String?)
        .compareTo(_semaRank(b['status'] as String?)));
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _statusSummary(l),
          if (_flags.isNotEmpty) ...[
            adminSectionTitle(l.t('adm_flags_title'), color: AdminColors.gray),
            Container(
              decoration: adminCardBox(),
              child: Column(children: [
                for (final e in _flags.entries) _flagRow(l, e.key, e.value as Map),
              ]),
            ),
          ],
          adminSectionTitle(l.t('adm_sec_sema'), color: AdminColors.teal),
          if (sorted.isEmpty)
            Padding(padding: const EdgeInsets.all(24),
                child: Center(child: Text(l.t('adm_audit_none'))))
          else
            Container(
              decoration: adminCardBox(),
              child: Column(children: [
                for (var i = 0; i < sorted.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, color: AdminColors.hairline),
                  _semaRow(l, sorted[i], df),
                ],
              ]),
            ),
        ],
      ),
    );
  }

  // Fila de un feature flag con switch. Descripción legible por clave conocida.
  Widget _flagRow(AppLocalizations l, String name, Map flag) {
    final on = flag['on'] == true;
    final busy = _flagBusy == name;
    final label = (flag['label'] as String?) ?? name;
    final desc = name == 'webhook_async' ? l.t('adm_flag_webhook_async_desc') : '';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 13, color: AdminColors.text)),
                if (desc.isNotEmpty)
                  Text(desc, style: const TextStyle(fontSize: 10.5, color: AdminColors.muted)),
              ],
            ),
          ),
          if (busy)
            const SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))
          else
            Switch(
              value: on,
              onChanged: (v) => _toggleFlag(name, v),
            ),
        ],
      ),
    );
  }

  Widget _semaRow(AppLocalizations l, Map<String, dynamic> s, DateFormat df) {
    final key = (s['key'] as String?) ?? '—';
    final status = (s['status'] as String?) ?? 'never';
    final at = DateTime.tryParse((s['at'] as String?) ?? '');
    final latency = (s['latency_ms'] as num?)?.toInt();
    final count = (s['count'] as num?)?.toInt();
    final color = _semaColor(status);
    final sub = at != null
        ? l.t('adm_sema_last', {'d': df.format(at)})
            + (latency != null ? ' · ${latency}ms' : '')
            + (count != null && count > 0
                ? ' · ${l.t('adm_sema_errcount', {'n': '$count'})}'
                : '')
        : l.t('adm_sema_nodata');
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
                Text(sub,
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

  // ── Métricas en vivo: uso de Groq (% disponible) + recursos de Supabase ────
  Widget _metricsView(AppLocalizations l) {
    final groq = (_metrics['groq'] as Map?)?.cast<String, dynamic>() ?? {};
    final supa = (_metrics['supabase'] as Map?)?.cast<String, dynamic>() ?? {};
    final sys = (supa['system'] as Map?)?.cast<String, dynamic>() ?? {};
    final db = (supa['db'] as Map?)?.cast<String, dynamic>() ?? {};

    final groqAvail = groq['available'] == true;
    final groqModels = ((groq['models'] as List?) ?? []).cast<Map<String, dynamic>>();
    final sysAvail = sys['available'] == true;

    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4, left: 4),
            child: Text(l.t('adm_metrics_intro'),
                style: const TextStyle(fontSize: 11, color: AdminColors.muted)),
          ),
          // IA / quota: % disponible por MODELO (parser + Whisper tienen su propio
          // rate-limit). Bajo = cerca del límite.
          _metricsBlock(l.t('adm_metrics_sec_ia'), AdminColors.purple, [
            if (!groqAvail || groqModels.isEmpty)
              _nodataRow(l, l.t('adm_metrics_groq_hint'))
            else
              for (final m in groqModels) ...[
                _bar(l, '${l.t('adm_metrics_groq_avail')} · ${m['model'] ?? '?'}',
                    (m['remaining_pct'] as num?)?.toInt(), invert: true),
                // Solo las filas con datos: Whisper (transcripción) solo tiene
                // peticiones; el parser tiene peticiones y tokens.
                if (_hasPair(m['requests'])) _kvRow(l.t('adm_metrics_reqs'), _fmtPair(m['requests'])),
                if (_hasPair(m['tokens'])) _kvRow(l.t('adm_metrics_tokens'), _fmtPair(m['tokens'])),
              ],
          ]),
          // Saturación: CPU/RAM/disco/carga del servidor (scrape, best-effort).
          _metricsBlock(l.t('adm_metrics_sec_sat'), AdminColors.blue, [
            if (sysAvail) ...[
              _bar(l, l.t('adm_metrics_cpu'), (sys['cpu_pct'] as num?)?.toInt()),
              _bar(l, l.t('adm_metrics_ram'), (sys['ram_pct'] as num?)?.toInt()),
              _bar(l, l.t('adm_metrics_disk'), (sys['disk_pct'] as num?)?.toInt()),
              if (sys['load1'] != null)
                _kvRow(l.t('adm_metrics_load'),
                    '${_num1(sys['load1'])} · ${_num1(sys['load5'])} · ${_num1(sys['load15'])}'),
            ] else
              _nodataRow(l, l.t('adm_metrics_supa_hint')),
          ]),
          // Base de datos (RPC, siempre disponible).
          if (db.isNotEmpty)
            _metricsBlock(l.t('adm_metrics_sec_db'), AdminColors.teal, [
              _kvRow(l.t('adm_metrics_db_size'),
                  (db['db_size_pretty'] ?? '—').toString()),
              _kvRow(l.t('adm_metrics_conns'),
                  '${db['connections'] ?? '—'} / ${db['max_connections'] ?? '—'}'
                  ' · ${db['connections_active'] ?? 0} ${l.t('adm_metrics_conns_active')}'
                  '${db['connections_idle'] != null ? ' · ${db['connections_idle']} ${l.t('adm_metrics_conns_idle')}' : ''}'),
              if (db['connections_waiting'] != null && (db['connections_waiting'] as num) > 0)
                _kvRow(l.t('adm_metrics_conns_waiting'), '${db['connections_waiting']}'),
              if (db['cache_hit_ratio'] != null)
                _bar(l, l.t('adm_metrics_cache'), (db['cache_hit_ratio'] as num?)?.round(), invert: true),
              if (db['oldest_txn_secs'] != null)
                _kvRow(l.t('adm_metrics_oldest_txn'), '${db['oldest_txn_secs']} s'),
              if (db['commits'] != null)
                _kvRow(l.t('adm_metrics_txns'),
                    '${_compact(db['commits'])} ✓ · ${_compact(db['rollbacks'])} ✗'),
              if (db['deadlocks'] != null && (db['deadlocks'] as num) > 0)
                _kvRow(l.t('adm_metrics_deadlocks'), '${db['deadlocks']}'),
            ]),
        ],
      ),
    );
  }

  // Bloque de métricas: título con acento (kit) + tarjeta con las filas.
  Widget _metricsBlock(String title, Color color, List<Widget> rows) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          adminSectionTitle(title, color: color),
          Container(
            decoration: adminCardBox(),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [...rows, const SizedBox(height: 6)]),
          ),
        ],
      );

  // Barra de uso con umbral. Uso (CPU/RAM/disco): >80% rojo, >60% ámbar.
  // Disponible (Groq, invert=true): <20% rojo, <40% ámbar (bajo = malo).
  Widget _bar(AppLocalizations l, String label, int? pct, {bool invert = false}) {
    final v = pct?.clamp(0, 100);
    Color c;
    bool alert;
    if (v == null) {
      c = AdminColors.gray; alert = false;
    } else if (invert) {
      alert = v < 20;
      c = v < 20 ? AdminColors.red : (v < 40 ? AdminColors.amber : AdminColors.teal);
    } else {
      alert = v > 80;
      c = v > 80 ? AdminColors.red : (v > 60 ? AdminColors.amber : AdminColors.teal);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(label,
              style: const TextStyle(fontSize: 12.5, color: AdminColors.text))),
          Text(v == null ? '—' : '$v%',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: c)),
        ]),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: v == null ? 0 : v / 100,
            minHeight: 7,
            backgroundColor: AdminColors.hairline,
            valueColor: AlwaysStoppedAnimation(c),
          ),
        ),
        if (alert)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(l.t('adm_metrics_alert80'),
                style: const TextStyle(
                    fontSize: 10.5, fontWeight: FontWeight.w600, color: AdminColors.red)),
          ),
      ]),
    );
  }

  Widget _kvRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: Row(children: [
          Expanded(child: Text(k,
              style: const TextStyle(fontSize: 12, color: AdminColors.muted))),
          Text(v, style: const TextStyle(fontSize: 12, color: AdminColors.text)),
        ]),
      );

  Widget _nodataRow(AppLocalizations l, String hint) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.t('adm_metrics_nodata'),
              style: const TextStyle(fontSize: 12.5, color: AdminColors.text)),
          const SizedBox(height: 2),
          Text(hint, style: const TextStyle(fontSize: 10.5, color: AdminColors.muted)),
        ]),
      );

  // ¿El par {remaining, limit} trae algún dato? (para no pintar filas vacías).
  bool _hasPair(dynamic m) => m is Map && (m['remaining'] != null || m['limit'] != null);

  // "restantes / límite" de un objeto {remaining, limit} del monitor de Groq.
  String _fmtPair(dynamic m) {
    if (m is! Map) return '—';
    final rem = m['remaining'], lim = m['limit'];
    if (rem == null && lim == null) return '—';
    return '${rem ?? '—'} / ${lim ?? '—'}';
  }

  // Número con 1 decimal (carga del sistema).
  String _num1(dynamic v) => (v is num) ? v.toStringAsFixed(2) : '—';

  // Número grande en forma compacta (1.2M, 34k…).
  String _compact(dynamic v) {
    if (v is! num) return '—';
    final n = v.toDouble();
    if (n >= 1e9) return '${(n / 1e9).toStringAsFixed(1)}B';
    if (n >= 1e6) return '${(n / 1e6).toStringAsFixed(1)}M';
    if (n >= 1e3) return '${(n / 1e3).toStringAsFixed(1)}k';
    return '${n.toInt()}';
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
                  Text(
                      '$admin · ${created != null ? df.format(created) : '—'}'
                      '${g['ip_address'] != null ? ' · ${g['ip_address']}' : ''}',
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
                Text(
                    '$admin · ${created != null ? df.format(created) : '—'}'
                    '${g['ip_address'] != null ? ' · IP ${g['ip_address']}' : ''}',
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
          if ((g['admin_id'] as String?)?.isNotEmpty == true &&
              _adminFilter != g['admin_id'])
            TextButton.icon(
              icon: const Icon(Icons.filter_alt, size: 16),
              onPressed: () {
                Navigator.pop(ctx);
                setState(() {
                  _adminFilter = g['admin_id'] as String;
                  _adminFilterLabel = admin;
                });
                _auditReload();
              },
              label: Text(l.t('adm_audit_filter_admin')),
            ),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(l.t('close'))),
        ],
      ),
    );
  }
}
