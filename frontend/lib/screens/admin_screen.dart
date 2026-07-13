import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import 'admin_company_detail_screen.dart';
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
        body: adminConstrained(children[m]),
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
    // Fila estilo "bandeja" (como la portada): etiqueta, texto y acción directa.
    return InkWell(
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => AdminIncidentChatScreen(incident: inc),
        ));
        _reload();
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: adminCardBox(),
        child: Row(
          children: [
            AdminTag(
              kind == 'app' ? l.t('adm_tag_ticket') : l.t('adm_tag_note'),
              fg: kind == 'app' ? AdminColors.blue : AdminColors.purple,
              bg: kind == 'app' ? AdminColors.blueBg : AdminColors.purpleBg,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(body, maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: resolved ? AdminColors.muted : AdminColors.text,
                        decoration: resolved ? TextDecoration.lineThrough : null,
                      )),
                  Text('$company · $author${hidden ? ' · ${l.t('admin_inc_hidden')}' : ''}',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10, color: AdminColors.muted)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            InkWell(
              onTap: () => _setStatus(inc['id'] as String, resolved ? 'abierta' : 'resuelta'),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  border: Border.all(
                      color: (resolved ? AdminColors.amber : AdminColors.teal)
                          .withValues(alpha: .55)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(resolved ? l.t('admin_reopen') : l.t('admin_resolve'),
                    style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w500,
                        color: resolved ? AdminColors.amber : AdminColors.teal)),
              ),
            ),
          ],
        ),
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
  bool _refreshing = false; // refresco silencioso en curso (auto o manual)
  String? _error;
  String _fLevel = '';
  String _fStatus = '';
  Timer? _autoRefresh;

  @override
  void initState() {
    super.initState();
    _reload();
    // "Tiempo real" pragmático: refresco silencioso cada 20 s para que los
    // nuevos logros y las revisiones aparezcan sin recargar a mano.
    _autoRefresh = Timer.periodic(const Duration(seconds: 20), (_) => _reload(silent: true));
  }

  @override
  void dispose() {
    _autoRefresh?.cancel();
    super.dispose();
  }

  Future<void> _reload({bool silent = false}) async {
    if (silent) {
      if (_refreshing) return; // evita solaparse con otro refresco
      _refreshing = true;
    } else {
      setState(() { _loading = true; _error = null; });
    }
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
      // Un fallo del refresco silencioso no debe romper la pantalla ya cargada.
      if (silent) return;
      setState(() { _error = e.toString().replaceFirst('Exception: ', ''); _loading = false; });
    } finally {
      if (silent) _refreshing = false;
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
    // Los sospechosos pendientes de decisión van ARRIBA: son lo accionable.
    final review = _filtered
        .where((c) => c['suspicious'] == true && (c['status_label'] as String?) != 'rejected')
        .toList();
    final rest = _filtered.where((c) => !review.contains(c)).toList();
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _summaryCards(l),
          if (review.isNotEmpty) ...[
            const SizedBox(height: 16),
            Row(children: [
              Container(width: 7, height: 7,
                  decoration: const BoxDecoration(
                      color: AdminColors.red, shape: BoxShape.circle)),
              const SizedBox(width: 7),
              Text(l.t('adm_ch_review_first').toUpperCase(),
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600,
                      letterSpacing: 1.5, color: AdminColors.text)),
            ]),
            const SizedBox(height: 8),
            for (final c in review) _claimTile(l, c),
          ],
          const SizedBox(height: 16),
          _filtersBar(l),
          const SizedBox(height: 8),
          if (rest.isEmpty && review.isEmpty)
            Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(l.t('admin_no_challenges'))))
          else
            for (final c in rest) _claimTile(l, c),
          const SizedBox(height: 16),
          _charts(l),
        ],
      ),
    );
  }

  // ── Resumen (KPIs) ─────────────────────────────────────────────────────
  Widget _summaryCards(AppLocalizations l) {
    num n(String k) => (_summary[k] as num?) ?? 0;
    return Wrap(spacing: 8, runSpacing: 8, children: [
      _kpi(Icons.emoji_events, l.t('adm_ch_kpi_completed'), '${n('total_completed')}', AdminColors.amber),
      _kpi(Icons.calendar_month, l.t('adm_ch_kpi_month'), '${n('completed_this_month')}', AdminColors.blue),
      _kpi(Icons.groups, l.t('adm_ch_kpi_drivers'), '${n('drivers_with_challenge')}%', AdminColors.blue),
      _kpi(Icons.trending_up, l.t('adm_ch_kpi_avglevel'), '${n('avg_level')}', AdminColors.purple),
      _kpi(Icons.savings, l.t('adm_ch_kpi_days_free'), l.t('fd_days', {'n': '${n('days_challenges').toInt()}'}), AdminColors.teal),
      _kpi(Icons.hourglass_bottom, l.t('adm_ch_kpi_pending'), '${n('pending_approvals')}', AdminColors.coral),
      _kpi(Icons.gpp_maybe, l.t('adm_ch_kpi_fraud'), '${n('fraud_rate')}%', AdminColors.red),
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
      _dailyChart(l),
      const SizedBox(height: 12),
      _kmDailyChart(l),
      const SizedBox(height: 12),
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

  // Evolución DIARIA (últimos 30 días): barras verticales compactas.
  Widget _dailyChart(AppLocalizations l) {
    final daily = ((_summary['daily'] as List?) ?? []).cast<Map<String, dynamic>>();
    final counts = daily.map((d) => (d['count'] as num?)?.toInt() ?? 0).toList();
    final max = counts.isEmpty ? 1 : counts.reduce((a, b) => a > b ? a : b);
    final total = counts.fold<int>(0, (s, v) => s + v);
    return Container(
      decoration: adminCardBox(),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text(l.t('adm_ch_chart_daily'),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              Text(l.t('adm_ch_last30', {'n': '$total'}),
                  style: const TextStyle(fontSize: 11, color: AdminColors.muted)),
            ]),
            const SizedBox(height: 12),
            SizedBox(
              height: 60,
              child: counts.isEmpty
                  ? Center(child: Text(l.t('admin_no_challenges'),
                      style: const TextStyle(fontSize: 12, color: AdminColors.muted)))
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (final c in counts)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 1),
                              child: Container(
                                height: max == 0 ? 2 : (2 + 56 * c / max),
                                decoration: BoxDecoration(
                                  color: c > 0 ? AdminColors.amber : AdminColors.hairline,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // Evolución de KM RECORRIDOS por día (últimos 30 días): visión global de cómo
  // avanzan los conductores hacia los retos, no solo cuándo los completan.
  Widget _kmDailyChart(AppLocalizations l) {
    final km = ((_summary['km_daily'] as List?) ?? []).cast<Map<String, dynamic>>();
    final vals = km.map((d) => (d['km'] as num?)?.toInt() ?? 0).toList();
    final max = vals.isEmpty ? 1 : vals.reduce((a, b) => a > b ? a : b);
    final total = vals.fold<int>(0, (s, v) => s + v);
    final fmt = NumberFormat.decimalPattern();
    return Container(
      decoration: adminCardBox(),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text(l.t('adm_ch_chart_km_daily'),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              Text(l.t('adm_ch_km_last30', {'n': fmt.format(total)}),
                  style: const TextStyle(fontSize: 11, color: AdminColors.muted)),
            ]),
            const SizedBox(height: 12),
            SizedBox(
              height: 60,
              child: (vals.isEmpty || total == 0)
                  ? Center(child: Text(l.t('adm_ch_km_empty'),
                      style: const TextStyle(fontSize: 12, color: AdminColors.muted)))
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (final v in vals)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 1),
                              child: Container(
                                height: max == 0 ? 2 : (2 + 56 * v / max),
                                decoration: BoxDecoration(
                                  color: v > 0 ? AdminColors.teal : AdminColors.hairline,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

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

  // ── Filtros de píldora (nivel + estado) ────────────────────────────────────
  // Fase 4 del rediseño: se retira el acceso a las recompensas trimestrales
  // (Loop #4, desactivadas desde Loop #6). El histórico sigue disponible por API.
  Widget _filtersBar(AppLocalizations l) {
    Widget pills(List<(String, String)> opts, String current, Color color,
            ValueChanged<String> onTap) =>
        SizedBox(
          height: 30,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final (v, label) in opts)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: AdminPill(
                      label: label, selected: current == v, color: color,
                      onTap: () => onTap(v)),
                ),
            ],
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      pills([
        ('', l.t('adm_ref_all')),
        ('approved', l.t('admin_ch_achieved')),
        ('pending', l.t('ref_status_pending')),
        ('rejected', l.t('admin_ch_rejected')),
      ], _fStatus, AdminColors.amber, (v) => setState(() => _fStatus = v)),
      const SizedBox(height: 6),
      pills([
        ('', '${l.t('adm_ch_filter_level')}: ${l.t('adm_ref_all')}'),
        for (var n = 1; n <= 5; n++) ('$n', '${l.t('adm_ch_filter_level')} $n'),
      ], _fLevel, AdminColors.purple, (v) => setState(() => _fLevel = v)),
    ]);
  }

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
    return InkWell(
      onTap: () => _openDetail(c['id'] as String),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: adminCardBox(
            borderColor: suspicious && !rejected ? AdminColors.red : null),
        child: Row(
          children: [
            Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                color: AdminColors.amberBg,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 18, color: AdminColors.amber),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text('$driver · $title',
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w500,
                              color: AdminColors.text)),
                    ),
                    const SizedBox(width: 6),
                    AdminTag('N$level',
                        fg: AdminColors.purple, bg: AdminColors.purpleBg),
                  ]),
                  Text(
                    '$company · ${l.t('admin_ch_goal')}: ${target.toStringAsFixed(0)} $unit · ${l.t('ch_days_progress', {'n': '$days', 'min': '300'})}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: AdminColors.muted),
                  ),
                  if (suspicious && !rejected)
                    Text('⚠ ${l.t('admin_ch_suspicious')}',
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 10, color: AdminColors.red)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (rejected)
              AdminTag(l.t('admin_ch_rejected'),
                  fg: AdminColors.muted, bg: AdminColors.hairline)
            else ...[
              AdminTag(l.t('admin_ch_achieved'),
                  fg: AdminColors.teal, bg: AdminColors.tealBg),
              const SizedBox(width: 6),
              InkWell(
                onTap: () => _review(c['id'] as String, 'reject'),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: AdminColors.redSolid.withValues(alpha: .55)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.block, size: 15, color: AdminColors.red),
                ),
              ),
            ],
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

    await showAdminDialog<void>(
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
          if (claim['user_id'] != null)
            TextButton.icon(
              onPressed: () async {
                Navigator.pop(ctx);
                await _correctKm(claim['user_id'] as String);
              },
              icon: const Icon(Icons.edit_road, size: 18),
              label: Text(l.t('adm_km_correct')),
            ),
          FilledButton.tonal(
            onPressed: () async { Navigator.pop(ctx); await _forceComplete(id); },
            child: Text(l.t('adm_ch_force')),
          ),
        ],
      ),
    );
  }

  // Corregir el km de un conductor: lista sus lecturas de cuentakilómetros
  // (inicio/cierre de jornada) y permite editar o borrar la que esté mal.
  Future<void> _correctKm(String userId) async {
    final l = context.l10n;
    List<Map<String, dynamic>> readings;
    try {
      readings = await _service.adminDriverOdometer(userId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
      return;
    }
    if (!mounted) return;
    final df = DateFormat('dd/MM/yyyy HH:mm');
    final fmt = NumberFormat.decimalPattern();
    await showAdminDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(l.t('adm_km_correct_title')),
          content: SizedBox(
            width: 460,
            child: readings.isEmpty
                ? Padding(padding: const EdgeInsets.all(16), child: Text(l.t('adm_km_none')))
                : SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      for (final r in readings)
                        _kmReadingRow(l, ctx, setLocal, readings, r, df, fmt),
                    ]),
                  ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.t('close'))),
          ],
        ),
      ),
    );
  }

  Widget _kmReadingRow(
      AppLocalizations l, BuildContext ctx, StateSetter setLocal,
      List<Map<String, dynamic>> entries, Map<String, dynamic> r,
      DateFormat df, NumberFormat fmt) {
    final id = r['id'] as String;
    final isTrip = r['source'] == 'transaction';
    final km = (r['km'] as num?)?.toInt() ?? 0;
    final at = DateTime.tryParse((r['at'] as String?) ?? '');
    final plate = (r['plate'] as String?) ?? '—';
    final srcLabel = isTrip ? l.t('adm_km_src_trip') : l.t('adm_km_src_reading');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text('${fmt.format(km)} km · $plate',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: AdminColors.text))),
              const SizedBox(width: 6),
              AdminTag(srcLabel,
                  fg: isTrip ? AdminColors.amber : AdminColors.blue,
                  bg: isTrip ? AdminColors.amberBg : AdminColors.blueBg),
            ]),
            Text(at != null ? df.format(at) : '—',
                style: const TextStyle(fontSize: 11, color: AdminColors.muted)),
          ]),
        ),
        IconButton(
          icon: const Icon(Icons.edit, size: 18, color: AdminColors.blue),
          tooltip: l.t('adm_km_new'),
          onPressed: () async {
            final newKm = await _askKm(km);
            if (newKm == null || newKm == km) return;
            try {
              if (isTrip) {
                await _service.adminCorrectTransactionOdometer(id, newKm);
              } else {
                await _service.adminCorrectOdometer(id, newKm);
              }
              r['km'] = newKm;
              setLocal(() {});
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('adm_km_saved'))));
              _reload(silent: true);
            } catch (e) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
            }
          },
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 18, color: AdminColors.red),
          tooltip: l.t('adm_km_del_confirm'),
          onPressed: () async {
            final ok = await showAdminDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                // En una carrera solo se borra el km (no la carrera entera).
                content: Text(isTrip ? l.t('adm_km_clear_confirm') : l.t('adm_km_del_confirm')),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.t('cancel'))),
                  FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(l.t('delete'))),
                ],
              ),
            );
            if (ok != true) return;
            try {
              if (isTrip) {
                await _service.adminCorrectTransactionOdometer(id, null);
              } else {
                await _service.adminDeleteOdometer(id);
              }
              entries.remove(r);
              setLocal(() {});
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('adm_km_deleted'))));
              _reload(silent: true);
            } catch (e) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
            }
          },
        ),
      ]),
    );
  }

  // Pide un nuevo valor de km (entero).
  Future<int?> _askKm(int current) async {
    final l = context.l10n;
    final ctrl = TextEditingController(text: '$current');
    return showAdminDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('adm_km_new')),
        content: TextField(
          controller: ctrl, autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: l.t('adm_km_new'), suffixText: 'km'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.t('cancel'))),
          FilledButton(
            onPressed: () {
              final v = int.tryParse(ctrl.text.trim().replaceAll('.', '').replaceAll(',', ''));
              Navigator.pop(ctx, v);
            },
            child: Text(l.t('save')),
          ),
        ],
      ),
    );
  }

  Future<void> _forceComplete(String id) async {
    final l = context.l10n;
    final ctrl = TextEditingController();
    final reason = await showAdminDialog<String>(
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
    return InkWell(
      onTap: () => _openReport(l, r, df),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: adminCardBox(),
        child: Row(
          children: [
            Icon(Icons.bug_report, size: 18, color: _statusColor(status)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(desc, maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, color: AdminColors.text)),
                  Text(
                    '$company · $author${created != null ? ' · ${df.format(created)}' : ''}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 10, color: AdminColors.muted),
                  ),
                  if (device.isNotEmpty)
                    Text(device,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 9, color: AdminColors.muted)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            AdminTag(_statusLabel(l, status),
                fg: _statusColor(status),
                bg: _statusColor(status).withValues(alpha: .16)),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, size: 15, color: AdminColors.muted),
          ],
        ),
      ),
    );
  }

  // Detalle del informe: texto completo, contexto y ACCIONES (cambiar estado
  // con un toque, abrir la ficha de la empresa afectada).
  Future<void> _openReport(
      AppLocalizations l, Map<String, dynamic> r, DateFormat df) async {
    final status = (r['status'] as String?) ?? 'new';
    final company = ((r['tenants'] as Map?)?['name'] as String?) ?? '—';
    final author = ((r['users'] as Map?)?['name'] as String?)
        ?? ((r['users'] as Map?)?['email'] as String?) ?? '—';
    final device = (r['device_info'] as String?) ?? '';
    final created = DateTime.tryParse((r['created_at'] as String?) ?? '');
    final tenantId = r['tenant_id'] as String?;
    await showAdminDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('adm_err_detail'), style: const TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$company · $author'
                  '${created != null ? ' · ${df.format(created)}' : ''}'
                  '${device.isNotEmpty ? '\n$device' : ''}',
                  style: const TextStyle(fontSize: 11, color: AdminColors.muted),
                ),
                const Divider(height: 16),
                SelectableText((r['description'] as String?) ?? '—',
                    style: const TextStyle(fontSize: 13)),
                const Divider(height: 16),
                Text(l.t('adm_err_change_status').toUpperCase(),
                    style: const TextStyle(
                        fontSize: 10, letterSpacing: 1.2,
                        color: AdminColors.muted)),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final s in ['new', 'viewed', 'in_progress', 'resolved'])
                    AdminPill(
                      label: _statusLabel(l, s),
                      selected: status == s,
                      color: _statusColor(s),
                      onTap: () {
                        Navigator.pop(ctx);
                        _setStatus(r['id'] as String, s);
                      },
                    ),
                ]),
              ],
            ),
          ),
        ),
        actions: [
          if (tenantId != null)
            TextButton.icon(
              icon: const Icon(Icons.business, size: 16, color: AdminColors.purple),
              label: Text(l.t('adm_open_company'),
                  style: const TextStyle(color: AdminColors.purple)),
              onPressed: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => AdminCompanyDetailScreen(
                      tenantId: tenantId, tenantName: company),
                ));
              },
            ),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(l.t('close'))),
        ],
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
