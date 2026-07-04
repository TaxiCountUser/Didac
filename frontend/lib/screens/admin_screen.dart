import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import 'admin_config_tab.dart';
import 'admin_theme.dart';
import 'admin_incident_chat_screen.dart';
import 'admin_referrals_tab.dart';
import 'admin_security_tab.dart';

/// Módulos del panel de administración como pantallas PROPIAS (sin la barra
/// de pestañas antigua): cada tarjeta de la portada abre su módulo con AppBar
/// oscura y título, igual que Empresas y Facturación.
/// 0 Soporte · 1 Retos · 2 Referidos · 3 Seguridad · 4 Errores · 5 Config.
class AdminModuleScreen extends StatelessWidget {
  final int module;
  const AdminModuleScreen({super.key, required this.module});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final m = module.clamp(0, 5);
    final titles = [
      l.t('adm_mod_support'),
      l.t('admin_challenges'),
      l.t('adm_ref_tab'),
      l.t('adm_sec_tab'),
      l.t('adm_err_tab'),
      l.t('adm_cfg_tab'),
    ];
    const children = <Widget>[
      _IncidentsTab(), _ChallengesTab(), ReferralsTab(),
      SecurityTab(), _ErrorReportsTab(), ConfigTab(),
    ];
    return Theme(
      data: adminDarkTheme(),
      child: Scaffold(
        backgroundColor: AdminColors.bg,
        appBar: AppBar(
          backgroundColor: AdminColors.bg,
          foregroundColor: AdminColors.text,
          elevation: 0,
          title: Text(titles[m],
              style: const TextStyle(fontSize: 16, color: AdminColors.text)),
          actions: [
            IconButton(
              tooltip: l.t('logout'),
              icon: const Icon(Icons.logout, size: 20, color: AdminColors.secondary),
              onPressed: () => Supabase.instance.client.auth.signOut(),
            ),
          ],
        ),
        body: children[m],
      ),
    );
  }
}

class _IncidentsTab extends StatefulWidget {
  const _IncidentsTab();
  @override
  State<_IncidentsTab> createState() => _IncidentsTabState();
}

class _IncidentsTabState extends State<_IncidentsTab> {
  final _service = DataService();
  bool _onlyOpen = true;
  late Future<List<Map<String, dynamic>>> _future = _load();

  Future<List<Map<String, dynamic>>> _load() =>
      _service.adminIncidents(status: _onlyOpen ? 'abierta' : null);

  void _reload() => setState(() => _future = _load());

  Future<void> _setStatus(String id, String status) async {
    try {
      await _service.adminSetIncidentStatus(id, status);
      _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
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
                label: l.t('admin_only_open'), selected: _onlyOpen,
                color: AdminColors.blue,
                onTap: () => setState(() { _onlyOpen = true; _future = _load(); })),
            const SizedBox(width: 6),
            AdminPill(
                label: l.t('adm_ref_all'), selected: !_onlyOpen,
                color: AdminColors.blue,
                onTap: () => setState(() { _onlyOpen = false; _future = _load(); })),
          ]),
        ),
        Expanded(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return _ErrorRetry(error: '${snap.error}', onRetry: _reload);
              }
              final list = snap.data ?? [];
              if (list.isEmpty) {
                return Center(child: Text(l.t('admin_no_incidents')));
              }
              return RefreshIndicator(
                onRefresh: () async => _reload(),
                child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: list.length,
                  itemBuilder: (context, i) => _incidentTile(l, list[i]),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _incidentTile(AppLocalizations l, Map<String, dynamic> inc) {
    final body = (inc['body'] as String?) ?? '';
    final kind = (inc['kind'] as String?) ?? 'nota';
    final status = (inc['status'] as String?) ?? 'abierta';
    final company = ((inc['tenants'] as Map?)?['name'] as String?) ?? '—';
    final author = ((inc['users'] as Map?)?['email'] as String?) ?? '—';
    final resolved = status == 'resuelta';
    final hidden = inc['hidden_for_tenant'] == true;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: adminCardBox(),
      child: ListTile(
        leading: AdminTag(
          kind == 'app' ? l.t('adm_tag_ticket') : l.t('adm_tag_note'),
          fg: kind == 'app' ? AdminColors.blue : AdminColors.purple,
          bg: kind == 'app' ? AdminColors.blueBg : AdminColors.purpleBg,
        ),
        title: Text(body, maxLines: 3, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13)),
        subtitle: Text('$company · $author${hidden ? ' · 🗑️ ${l.t('admin_inc_hidden')}' : ''}',
            style: const TextStyle(fontSize: 11, color: AdminColors.muted)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: resolved ? l.t('admin_reopen') : l.t('admin_resolve'),
              icon: Icon(resolved ? Icons.replay : Icons.check_circle,
                  color: resolved ? AdminColors.amber : AdminColors.teal),
              onPressed: () => _setStatus(inc['id'] as String, resolved ? 'abierta' : 'resuelta'),
            ),
            const Icon(Icons.chat_bubble_outline, size: 18, color: AdminColors.muted),
          ],
        ),
        // Abrir el chat para hablar con el cliente hasta cerrar la avería.
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => AdminIncidentChatScreen(incident: inc),
          ));
          _reload();
        },
      ),
    );
  }
}

class _ChallengesTab extends StatefulWidget {
  const _ChallengesTab();
  @override
  State<_ChallengesTab> createState() => _ChallengesTabState();
}

class _ChallengesTabState extends State<_ChallengesTab> {
  final _service = DataService();
  List<Map<String, dynamic>> _claims = [];
  Map<String, dynamic> _summary = {};
  bool _loading = true;
  String? _error;
  String _fLevel = '';
  String _fStatus = '';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([_service.adminChallenges(), _service.adminChallengeSummary()]);
      if (!mounted) return;
      setState(() {
        _claims = (results[0] as List).cast<Map<String, dynamic>>();
        _summary = results[1] as Map<String, dynamic>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString().replaceFirst('Exception: ', ''); _loading = false; });
    }
  }

  Future<void> _review(String id, String action) async {
    try {
      await _service.adminReviewChallenge(id, action);
      _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  List<Map<String, dynamic>> get _filtered => _claims.where((c) {
        if (_fLevel.isNotEmpty && ((c['level'] as num?)?.toInt() ?? 0) != int.parse(_fLevel)) return false;
        if (_fStatus.isNotEmpty && (c['status_label'] as String?) != _fStatus) return false;
        return true;
      }).toList();

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    if (_error != null) return _ErrorRetry(error: _error!, onRetry: _reload);
    if (_loading) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _summaryCards(l),
          const SizedBox(height: 16),
          _charts(l),
          const SizedBox(height: 16),
          _filtersBar(l),
          const SizedBox(height: 8),
          if (_filtered.isEmpty)
            Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(l.t('admin_no_challenges'))))
          else
            for (final c in _filtered) _claimTile(l, c),
        ],
      ),
    );
  }

  // ── Resumen (KPIs) ─────────────────────────────────────────────────────
  Widget _summaryCards(AppLocalizations l) {
    num n(String k) => (_summary[k] as num?) ?? 0;
    return Wrap(spacing: 8, runSpacing: 8, children: [
      _kpi(Icons.emoji_events, l.t('adm_ch_kpi_completed'), '${n('total_completed')}', AdminColors.amber),
      _kpi(Icons.groups, l.t('adm_ch_kpi_drivers'), '${n('drivers_with_challenge')}%', AdminColors.blue),
      _kpi(Icons.trending_up, l.t('adm_ch_kpi_avglevel'), '${n('avg_level')}', AdminColors.purple),
      _kpi(Icons.card_giftcard, l.t('adm_ch_kpi_days'), '${n('days_awarded')}', AdminColors.teal),
      _kpi(Icons.hourglass_bottom, l.t('adm_ch_kpi_pending'), '${n('pending_approvals')}', AdminColors.coral),
    ]);
  }

  Widget _kpi(IconData icon, String label, String value, Color color) =>
      AdminKpiTile(width: 150, icon: icon, label: label, value: value, color: color);

  // ── Gráficos (sin dependencias: barras con Containers) ─────────────────────
  Widget _charts(AppLocalizations l) {
    final approved = _claims.where((c) => (c['status_label'] as String?) == 'approved').toList();

    // Distribución por nivel (1..5, 5+).
    final byLevel = <int, int>{};
    for (final c in approved) {
      var lvl = (c['level'] as num?)?.toInt() ?? 1;
      if (lvl > 5) lvl = 5;
      byLevel[lvl] = (byLevel[lvl] ?? 0) + 1;
    }
    // Evolución mensual (últimos 12 meses).
    final byMonth = <String, int>{};
    final now = DateTime.now();
    for (int i = 11; i >= 0; i--) {
      final d = DateTime(now.year, now.month - i);
      byMonth['${d.year}-${d.month.toString().padLeft(2, '0')}'] = 0;
    }
    for (final c in approved) {
      final dt = DateTime.tryParse((c['reviewed_at'] ?? c['created_at']) as String? ?? '');
      if (dt == null) continue;
      final key = '${dt.year}-${dt.month.toString().padLeft(2, '0')}';
      if (byMonth.containsKey(key)) byMonth[key] = byMonth[key]! + 1;
    }
    // Top 10 conductores por nº de retos aprobados.
    final byDriver = <String, int>{};
    for (final c in approved) {
      final name = ((c['users'] as Map?)?['name'] as String?)
          ?? ((c['users'] as Map?)?['email'] as String?) ?? '—';
      byDriver[name] = (byDriver[name] ?? 0) + 1;
    }
    final top = byDriver.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    return Column(children: [
      _chartCard(l.t('adm_ch_chart_levels'), [
        for (int lvl = 1; lvl <= 5; lvl++)
          _bar(l.t('ch_level', {'n': lvl == 5 ? '5+' : '$lvl'}), byLevel[lvl] ?? 0,
              _maxVal(byLevel.values), AdminColors.purple),
      ]),
      const SizedBox(height: 12),
      _chartCard(l.t('adm_ch_chart_monthly'), [
        for (final e in byMonth.entries)
          _bar(e.key.substring(2), e.value, _maxVal(byMonth.values), AdminColors.teal),
      ]),
      const SizedBox(height: 12),
      _chartCard(l.t('adm_ch_chart_top'), [
        if (top.isEmpty) Text(l.t('admin_no_challenges'), style: const TextStyle(color: AdminColors.muted, fontSize: 12)),
        for (final e in top.take(10))
          _bar(e.key, e.value, top.first.value, AdminColors.amber),
      ]),
    ]);
  }

  int _maxVal(Iterable<int> v) => v.isEmpty ? 1 : v.reduce((a, b) => a > b ? a : b);

  Widget _chartCard(String title, List<Widget> bars) => Container(
        decoration: adminCardBox(),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            ...bars,
          ]),
        ),
      );

  Widget _bar(String label, int value, int max, Color color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          SizedBox(width: 70, child: Text(label, style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis)),
          Expanded(
            child: LayoutBuilder(builder: (ctx, cons) {
              final frac = max == 0 ? 0.0 : (value / max).clamp(0.0, 1.0);
              return Stack(children: [
                Container(height: 16, decoration: BoxDecoration(
                    color: AdminColors.hairline, borderRadius: BorderRadius.circular(4))),
                Container(height: 16, width: cons.maxWidth * frac,
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4))),
              ]);
            }),
          ),
          SizedBox(width: 34, child: Text('$value', textAlign: TextAlign.right, style: const TextStyle(fontSize: 11))),
        ]),
      );

  // ── Filtros ────────────────────────────────────────────────────────────────
  // Fase 4 del rediseño: se retira el acceso a las recompensas trimestrales
  // (Loop #4, desactivadas desde Loop #6). El histórico sigue disponible por API.
  Widget _filtersBar(AppLocalizations l) => Wrap(
        spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _ddown(l.t('adm_ch_filter_level'), _fLevel, {
            '': l.t('adm_ref_all'), '1': '1', '2': '2', '3': '3', '4': '4', '5': '5',
          }, (v) => setState(() => _fLevel = v)),
          _ddown(l.t('adm_ref_status'), _fStatus, {
            '': l.t('adm_ref_all'),
            'approved': l.t('admin_ch_achieved'),
            'pending': l.t('ref_status_pending'),
            'rejected': l.t('admin_ch_rejected'),
          }, (v) => setState(() => _fStatus = v)),
        ],
      );

  Widget _ddown(String label, String value, Map<String, String> opts, ValueChanged<String> onChanged) => SizedBox(
        width: 160,
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

  Widget _claimTile(AppLocalizations l, Map<String, dynamic> c) {
    final challenge = (c['challenge'] as String?) ?? '';
    final isKm = challenge == 'km_100k';
    final isDays = challenge == 'days_300';
    final level = (c['level'] as num?)?.toInt() ?? 1;
    final target = (c['target'] as num?)?.toDouble() ?? 0;
    final days = (c['active_days'] as num?)?.toInt() ?? 0;
    final status = (c['status'] as String?) ?? 'pending';
    final suspicious = c['suspicious'] == true;
    final driver = ((c['users'] as Map?)?['name'] as String?)
        ?? ((c['users'] as Map?)?['email'] as String?) ?? '—';
    final company = ((c['tenants'] as Map?)?['name'] as String?) ?? '—';
    final rejected = status == 'rejected';
    final unit = isKm ? 'km' : (isDays ? l.t('ch_days_unit') : '€');
    final title = isKm ? l.t('ch_km_label') : (isDays ? l.t('ch_days_label') : l.t('ch_money_label'));
    final icon = isKm ? Icons.speed : (isDays ? Icons.calendar_today : Icons.euro);
    // Loop #4: ya no hay aprobación manual (los retos se auto-registran y la
    // recompensa es trimestral por flota). El admin solo puede RECHAZAR por
    // fraude un logro, lo que lo excluye de la métrica trimestral.
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: adminCardBox(
          borderColor: suspicious ? AdminColors.red : null),
      child: ListTile(
        onTap: () => _openDetail(c['id'] as String),
        leading: Icon(icon, color: AdminColors.amber),
        title: Text('$title · ${l.t('ch_level', {'n': '$level'})} · $driver',
            style: const TextStyle(fontSize: 13)),
        subtitle: Text('$company\n'
            '${l.t('admin_ch_goal')}: ${target.toStringAsFixed(0)} $unit · ${l.t('ch_days_progress', {'n': '$days', 'min': '300'})}'
            '${suspicious ? '\n⚠️ ${l.t('admin_ch_suspicious')}' : ''}',
            style: TextStyle(
                fontSize: 11,
                color: suspicious ? AdminColors.red : AdminColors.muted)),
        isThreeLine: true,
        trailing: rejected
            ? AdminTag(l.t('admin_ch_rejected'),
                fg: AdminColors.muted, bg: AdminColors.hairline)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AdminTag(l.t('admin_ch_achieved'),
                      fg: AdminColors.teal, bg: AdminColors.tealBg),
                  IconButton(
                    tooltip: l.t('admin_ch_fraud'),
                    icon: const Icon(Icons.block, color: AdminColors.red),
                    onPressed: () => _review(c['id'] as String, 'reject'),
                  ),
                ],
              ),
      ),
    );
  }

  // ── Detalle ampliado de un reto ──────────────────────────────────────────
  Future<void> _openDetail(String id) async {
    final l = context.l10n;
    Map<String, dynamic>? data;
    try {
      data = await _service.adminChallengeDetail(id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
      return;
    }
    if (!mounted) return;
    final claim = (data['claim'] as Map?) ?? {};
    final driver = ((claim['users'] as Map?)?['name'] as String?)
        ?? ((claim['users'] as Map?)?['email'] as String?) ?? '—';
    final levels = (data['current_levels'] as Map?) ?? {};
    final fleetAvg = (data['fleet_avg_level'] as num?)?.toStringAsFixed(1) ?? '—';
    final history = ((data['driver_history'] as List?) ?? []).cast<Map<String, dynamic>>();
    final df = DateFormat('dd/MM/yyyy');

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(driver),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('${l.t('adm_ch_current_levels')}: '
                  'km ${levels['km_100k'] ?? 1} · € ${levels['money_100k'] ?? 1} · '
                  '${l.t('ch_days_unit')} ${levels['days_300'] ?? 1}',
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 4),
              Text('${l.t('adm_ch_fleet_avg')}: $fleetAvg', style: const TextStyle(fontSize: 13, color: Colors.blueGrey)),
              const Divider(),
              Text(l.t('adm_ch_history'), style: const TextStyle(fontWeight: FontWeight.bold)),
              for (final h in history)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('• ${h['challenge']} · ${l.t('ch_level', {'n': '${h['level']}'})} · ${h['status_label']}'
                      ' — ${DateTime.tryParse((h['created_at'] as String?) ?? '') != null ? df.format(DateTime.parse(h['created_at'])) : ''}',
                      style: const TextStyle(fontSize: 12)),
                ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.t('close'))),
          FilledButton.tonal(
            onPressed: () async { Navigator.pop(ctx); await _forceComplete(id); },
            child: Text(l.t('adm_ch_force')),
          ),
        ],
      ),
    );
  }

  Future<void> _forceComplete(String id) async {
    final l = context.l10n;
    final ctrl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('adm_ch_force')),
        content: TextField(controller: ctrl, autofocus: true,
            decoration: InputDecoration(labelText: l.t('adm_ch_force_reason'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text(l.t('adm_ch_force'))),
        ],
      ),
    );
    if (reason == null || reason.isEmpty) return;
    try {
      await _service.adminChallengeForceComplete(id, reason);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('adm_ch_forced'))));
      _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

}

// ── Informes de error (Loop #6) ─────────────────────────────────────────────
// Solo el admin de plataforma ve esta pestaña. El jefe recibe copia por push
// pero no tiene acceso aquí (RLS + esta pantalla es del panel admin).
class _ErrorReportsTab extends StatefulWidget {
  const _ErrorReportsTab();
  @override
  State<_ErrorReportsTab> createState() => _ErrorReportsTabState();
}

class _ErrorReportsTabState extends State<_ErrorReportsTab> {
  final _service = DataService();
  String _status = ''; // '' = todos
  late Future<List<Map<String, dynamic>>> _future = _load();

  Future<List<Map<String, dynamic>>> _load() =>
      _service.adminErrorReports(status: _status.isEmpty ? null : _status);

  void _reload() => setState(() => _future = _load());

  Future<void> _setStatus(String id, String status) async {
    try {
      await _service.adminSetErrorReportStatus(id, status);
      _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  String _statusLabel(AppLocalizations l, String s) => switch (s) {
        'new' => l.t('adm_err_new'),
        'viewed' => l.t('adm_err_viewed'),
        'in_progress' => l.t('adm_err_in_progress'),
        'resolved' => l.t('adm_err_resolved'),
        _ => s,
      };

  Color _statusColor(String s) => switch (s) {
        'resolved' => AdminColors.teal,
        'in_progress' => AdminColors.blue,
        'viewed' => AdminColors.gray,
        _ => AdminColors.coral, // new
      };

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: SizedBox(
            height: 30,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final (s, label) in [
                  ('', l.t('adm_ref_all')),
                  ('new', l.t('adm_err_new')),
                  ('viewed', l.t('adm_err_viewed')),
                  ('in_progress', l.t('adm_err_in_progress')),
                  ('resolved', l.t('adm_err_resolved')),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: AdminPill(
                      label: label,
                      selected: _status == s,
                      color: s.isEmpty ? AdminColors.coral : _statusColor(s),
                      onTap: () { _status = s; _reload(); },
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return _ErrorRetry(error: '${snap.error}', onRetry: _reload);
              }
              final list = snap.data ?? [];
              if (list.isEmpty) {
                return Center(child: Text(l.t('adm_err_empty')));
              }
              return RefreshIndicator(
                onRefresh: () async => _reload(),
                child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: list.length,
                  itemBuilder: (context, i) => _reportTile(l, list[i]),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _reportTile(AppLocalizations l, Map<String, dynamic> r) {
    final desc = (r['description'] as String?) ?? '';
    final status = (r['status'] as String?) ?? 'new';
    final company = ((r['tenants'] as Map?)?['name'] as String?) ?? '—';
    final author = ((r['users'] as Map?)?['name'] as String?)
        ?? ((r['users'] as Map?)?['email'] as String?) ?? '—';
    final device = (r['device_info'] as String?) ?? '';
    final created = DateTime.tryParse((r['created_at'] as String?) ?? '');
    final df = DateFormat('dd/MM/yyyy HH:mm');
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: adminCardBox(),
      child: ListTile(
        leading: Icon(Icons.bug_report, color: _statusColor(status)),
        title: Text(desc, maxLines: 4, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13)),
        subtitle: Text([
          '$company · $author',
          if (device.isNotEmpty) device,
          if (created != null) df.format(created),
        ].join('\n'),
            style: const TextStyle(fontSize: 11, color: AdminColors.muted)),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          tooltip: l.t('adm_err_change_status'),
          onSelected: (s) => _setStatus(r['id'] as String, s),
          child: AdminTag(_statusLabel(l, status),
              fg: _statusColor(status),
              bg: _statusColor(status).withValues(alpha: .16)),
          itemBuilder: (ctx) => [
            for (final s in ['new', 'viewed', 'in_progress', 'resolved'])
              PopupMenuItem(value: s, child: Text(_statusLabel(l, s))),
          ],
        ),
      ),
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorRetry({required this.error, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${l.t('error')}: ${error.replaceFirst('Exception: ', '')}',
              textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: Text(l.t('retry'))),
        ],
      ),
    );
  }
}
