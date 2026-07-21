import 'dart:async';

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
/// 0 Soporte · 1 Retos · 2 Referidos · 3 Monitorización · 4 Config · 5 Auditoría.
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
      l.t('adm_mon_tab'),
      l.t('adm_cfg_tab'),
      l.t('adm_audit_tab'),
    ];
    const children = <Widget>[
      _IncidentsTab(), _ChallengesTab(), ReferralsTab(),
      SecurityTab(mode: 'monitoring'), ConfigTab(),
      SecurityTab(mode: 'audit'),
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
            const SizedBox(width: 4),
            IconButton(
              tooltip: l.t('delete'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline, size: 18, color: AdminColors.red),
              onPressed: () => _deleteIncident(l, inc['id'] as String),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteIncident(AppLocalizations l, String id) async {
    final ok = await showAdminDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l.t('adm_ticket_delete_title')),
        content: Text(l.t('adm_ticket_delete_msg')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(l.t('delete'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _service.adminDeleteIncident(id);
      _reload();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('adm_ticket_deleted'))));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
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
  int _tab = 0; // 0 = resumen (KPIs + gráficos + logros), 1 = sospechosos
  String _evoPeriod = 'days'; // días | months | years | total
  int? _kmSelDay; // índice del día seleccionado en el gráfico de km/día
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

  Future<void> _review(String id, String action, {String? reason}) async {
    try {
      await _service.adminReviewChallenge(id, action, reason: reason);
      _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  // Rechazar por fraude pide un MOTIVO (opcional pero recomendado, estándar de
  // moderación T&S): queda registrado en Auditoría junto a la acción.
  Future<void> _rejectWithReason(String id) async {
    final l = context.l10n;
    final ctrl = TextEditingController();
    final ok = await showAdminDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('adm_ch_reject_title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.t('adm_ch_reject_help'), style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLength: 300,
              maxLines: 2,
              decoration: InputDecoration(
                  labelText: l.t('adm_ch_reject_reason'), isDense: true),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.t('cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AdminColors.redSolid),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.t('adm_ch_reject_confirm')),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _review(id, 'reject', reason: ctrl.text.trim());
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
    // Sospechosos = TODOS los marcados por fraude (pendientes Y rechazados): así
    // un rechazado sale aquí y NO en Logros. El número entre paréntesis solo
    // cuenta los PENDIENTES de decisión (accionables); una vez decidido, no suma.
    final suspicious = _claims.where((c) => c['suspicious'] == true).toList();
    final pendingCount = suspicious
        .where((c) => (c['status_label'] as String?) == 'pending').length;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Row(children: [
          AdminPill(
              label: l.t('adm_ch_tab_summary'), selected: _tab == 0, color: AdminColors.amber,
              onTap: () => setState(() => _tab = 0)),
          const SizedBox(width: 6),
          AdminPill(
              label: l.t('adm_ch_achievements'), selected: _tab == 1, color: AdminColors.teal,
              onTap: () => setState(() => _tab = 1)),
          const SizedBox(width: 6),
          AdminPill(
              label: pendingCount > 0
                  ? '${l.t('adm_ch_tab_suspicious')} ($pendingCount)'
                  : l.t('adm_ch_tab_suspicious'),
              selected: _tab == 2, color: AdminColors.red,
              onTap: () => setState(() => _tab = 2)),
        ]),
      ),
      Expanded(child: switch (_tab) {
        1 => _achievementsView(l),
        2 => _suspiciousView(l, suspicious),
        _ => _summaryView(l),
      }),
    ]);
  }

  // Tab 0: bloques con título (engagement · coste · moderación · gráficos), al
  // estilo de Facturación, para que el módulo se lea por secciones.
  Widget _summaryView(AppLocalizations l) {
    num n(String k) => (_summary[k] as num?) ?? 0;
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          adminSectionTitle(l.t('adm_ch_sec_engagement'),
              color: AdminColors.amber),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _kpi(Icons.emoji_events, l.t('adm_ch_kpi_completed'),
                '${n('total_completed')}', AdminColors.amber),
            _kpi(Icons.calendar_month, l.t('adm_ch_kpi_month'),
                '${n('completed_this_month')}', AdminColors.blue),
            _kpi(Icons.groups, l.t('adm_ch_kpi_drivers'),
                '${n('drivers_with_challenge')}%', AdminColors.blue),
            _kpi(Icons.percent, l.t('adm_ch_kpi_completion'),
                '${n('completion_rate')}%', AdminColors.purple),
          ]),
          adminSectionTitle(l.t('adm_ch_sec_cost'), color: AdminColors.teal),
          _rewardCard(l),
          adminSectionTitle(l.t('adm_ch_sec_moderation'),
              color: AdminColors.red),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _kpi(Icons.hourglass_bottom, l.t('adm_ch_kpi_pending'),
                '${n('pending_approvals')}', AdminColors.coral),
            _kpi(Icons.gpp_maybe, l.t('adm_ch_kpi_fraud'),
                '${n('fraud_rate')}%', AdminColors.red),
          ]),
          adminSectionTitle(l.t('adm_ch_sec_charts'),
              color: AdminColors.purple),
          _charts(l),
        ],
      ),
    );
  }

  // Coste del programa de recompensas destacado (lo que REGALAMOS): € + días + %.
  Widget _rewardCard(AppLocalizations l) {
    num n(String k) => (_summary[k] as num?) ?? 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: adminCardBox(),
      child: Row(children: [
        const Icon(Icons.savings, size: 18, color: AdminColors.teal),
        const SizedBox(width: 10),
        Expanded(
          child: Text(l.t('adm_ch_kpi_reward_cost'),
              style: const TextStyle(
                  fontSize: 10.5, color: AdminColors.secondary)),
        ),
        Text('${n('reward_cost_eur').toStringAsFixed(2)}€',
            style: const TextStyle(
                fontSize: 20, fontWeight: FontWeight.w700,
                color: AdminColors.text)),
        const SizedBox(width: 6),
        Text(
            '${l.t('fd_days', {'n': '${n('days_challenges').toInt()}'})} · ${n('reward_pct')}%',
            style: const TextStyle(fontSize: 9, color: AdminColors.muted)),
      ]),
    );
  }

  // Tab 1: LOGROS = solo retos COMPLETADOS (rewarded/approved). Un rechazado no
  // aparece aquí (sale en Sospechosos).
  Widget _achievementsView(AppLocalizations l) {
    final approved = _filtered
        .where((c) => (c['status_label'] as String?) == 'approved')
        .toList();
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _filtersBar(l),
          const SizedBox(height: 8),
          if (approved.isEmpty)
            Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(l.t('admin_no_challenges'))))
          else
            for (final c in approved) _claimTile(l, c),
        ],
      ),
    );
  }

  // Tab 2: conductores marcados como sospechosos (salto de fraude): pendientes
  // (para aceptar/rechazar) y también los ya rechazados.
  Widget _suspiciousView(AppLocalizations l, List<Map<String, dynamic>> suspicious) {
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 4),
            child: Text(l.t('adm_ch_suspicious_intro'),
                style: const TextStyle(fontSize: 11, color: AdminColors.muted)),
          ),
          if (suspicious.isEmpty)
            Padding(padding: const EdgeInsets.all(24),
                child: Center(child: Text(l.t('adm_ch_no_suspicious'))))
          else
            for (final c in suspicious) _claimTile(l, c),
        ],
      ),
    );
  }

  // ── Resumen (KPIs) ─────────────────────────────────────────────────────
  Widget _kpi(IconData icon, String label, String value, Color color) =>
      AdminKpiTile(
          width: 150, icon: icon, label: label, value: value, color: color);

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
    // Top 10 conductores por nº de retos aprobados.
    final byDriver = <String, int>{};
    for (final c in approved) {
      final name = ((c['users'] as Map?)?['name'] as String?)
          ?? ((c['users'] as Map?)?['email'] as String?) ?? '—';
      byDriver[name] = (byDriver[name] ?? 0) + 1;
    }
    final top = byDriver.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    return Column(children: [
      // 1º: km recorridos por día (visión global del avance).
      _kmDailyChart(l),
      const SizedBox(height: 12),
      // 2º: evolución de retos completados, con selector de periodo
      // (días/meses/años/total) que sustituye la antigua "Evolución mensual".
      _evolutionChart(l, approved),
      const SizedBox(height: 12),
      _chartCard(l.t('adm_ch_chart_levels'), [
        for (int lvl = 1; lvl <= 5; lvl++)
          _bar(l.t('ch_level', {'n': lvl == 5 ? '5+' : '$lvl'}), byLevel[lvl] ?? 0,
              _maxVal(byLevel.values), AdminColors.purple),
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

  // Evolución de retos completados con selector de periodo: días (30), meses
  // (12), años, o total (todos los años). Sustituye a la "evolución mensual".
  Widget _evolutionChart(AppLocalizations l, List<Map<String, dynamic>> approved) {
    final now = DateTime.now();
    // Fecha de cada logro (reviewed_at o created_at).
    DateTime? at(Map<String, dynamic> c) =>
        DateTime.tryParse((c['reviewed_at'] ?? c['created_at']) as String? ?? '');

    // Construye las etiquetas (clave) ordenadas y cuenta por bucket.
    final labels = <String>[];
    final counts = <String, int>{};
    if (_evoPeriod == 'days') {
      for (int i = 29; i >= 0; i--) {
        final d = now.subtract(Duration(days: i));
        final k = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
        labels.add(k); counts[k] = 0;
      }
      for (final c in approved) {
        final d = at(c);
        if (d == null) continue;
        final k = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
        if (counts.containsKey(k)) counts[k] = counts[k]! + 1;
      }
    } else if (_evoPeriod == 'months') {
      for (int i = 11; i >= 0; i--) {
        final d = DateTime(now.year, now.month - i);
        final k = '${d.year}-${d.month.toString().padLeft(2, '0')}';
        labels.add(k); counts[k] = 0;
      }
      for (final c in approved) {
        final d = at(c);
        if (d == null) continue;
        final k = '${d.year}-${d.month.toString().padLeft(2, '0')}';
        if (counts.containsKey(k)) counts[k] = counts[k]! + 1;
      }
    } else if (_evoPeriod == 'years') {
      final years = approved.map((c) => at(c)?.year).whereType<int>().toSet().toList()..sort();
      for (final y in years) { labels.add('$y'); counts['$y'] = 0; }
      for (final c in approved) {
        final y = at(c)?.year;
        if (y != null) counts['$y'] = (counts['$y'] ?? 0) + 1;
      }
    } else {
      // TOTAL: una sola barra con todos los logros desde el arranque de la app.
      labels.add('total'); counts['total'] = approved.length;
    }
    final maxV = _maxVal(counts.values);

    // Etiqueta del eje según periodo. En 'días' solo se muestran algunas (para
    // que no se solapen); en el resto, todas.
    final step = (labels.length / 6).ceil().clamp(1, 999);
    bool showLabelAt(int i) => _evoPeriod != 'days' || i == 0 || i == labels.length - 1 || i % step == 0;
    String short(String k) {
      if (_evoPeriod == 'total') return l.t('adm_ch_period_total');
      if (_evoPeriod == 'days') return '${k.substring(8)}/${k.substring(5, 7)}'; // DD/MM
      if (_evoPeriod == 'months') return k.substring(2); // YY-MM
      return k; // año
    }

    return Container(
      decoration: adminCardBox(),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(l.t('adm_ch_chart_evolution'),
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
          ]),
          const SizedBox(height: 8),
          // Selector de periodo.
          SizedBox(
            height: 28,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final (v, lbl) in [
                ('days', l.t('adm_ch_period_days')),
                ('months', l.t('adm_ch_period_months')),
                ('years', l.t('adm_ch_period_years')),
                ('total', l.t('adm_ch_period_total')),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: AdminPill(label: lbl, selected: _evoPeriod == v, color: AdminColors.teal,
                      onTap: () => setState(() => _evoPeriod = v)),
                ),
            ]),
          ),
          const SizedBox(height: 12),
          if (labels.isEmpty || (_evoPeriod == 'total' && approved.isEmpty))
            Padding(padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(l.t('admin_no_challenges'),
                    style: const TextStyle(fontSize: 12, color: AdminColors.muted)))
          else
            // Mismo estilo para TODOS los periodos: barras verticales con eje.
            SizedBox(
              height: 84,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < labels.length; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (counts[labels[i]]! > 0 && (labels.length <= 12 || showLabelAt(i)))
                              Text('${counts[labels[i]]}',
                                  style: const TextStyle(fontSize: 9, color: AdminColors.muted)),
                            Container(
                              height: maxV == 0 ? 2 : (2 + 46 * counts[labels[i]]! / maxV),
                              decoration: BoxDecoration(
                                color: counts[labels[i]]! > 0 ? AdminColors.teal : AdminColors.hairline,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(height: 3),
                            SizedBox(
                              height: 20,
                              child: showLabelAt(i)
                                  ? Text(short(labels[i]),
                                      maxLines: 1, overflow: TextOverflow.visible,
                                      style: const TextStyle(fontSize: 8, color: AdminColors.muted))
                                  : null,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ]),
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
    // Índice seleccionado válido (si cambió el nº de días, se ignora).
    final sel = (_kmSelDay != null && _kmSelDay! >= 0 && _kmSelDay! < km.length) ? _kmSelDay : null;
    String dayLabel(int i) {
      final d = DateTime.tryParse('${km[i]['day']}');
      if (d == null) return '';
      return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
    }
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
              // Si hay un día seleccionado, muestra su fecha + km; si no, el total.
              sel != null
                  ? Text('${dayLabel(sel)} · ${fmt.format(vals[sel])} km',
                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AdminColors.teal))
                  : Text(l.t('adm_ch_km_last30', {'n': fmt.format(total)}),
                      style: const TextStyle(fontSize: 11, color: AdminColors.muted)),
            ]),
            const SizedBox(height: 4),
            Text(sel != null ? l.t('adm_ch_km_tap_hint_sel') : l.t('adm_ch_km_tap_hint'),
                style: const TextStyle(fontSize: 10, color: AdminColors.muted)),
            const SizedBox(height: 8),
            SizedBox(
              height: 60,
              child: (vals.isEmpty || total == 0)
                  ? Center(child: Text(l.t('adm_ch_km_empty'),
                      style: const TextStyle(fontSize: 12, color: AdminColors.muted)))
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < vals.length; i++)
                          Expanded(
                            // Toda la columna es zona táctil (aunque la barra sea baja).
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => setState(() => _kmSelDay = sel == i ? null : i),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 1),
                                child: Align(
                                  alignment: Alignment.bottomCenter,
                                  child: Container(
                                    height: max == 0 ? 2 : (2 + 56 * vals[i] / max),
                                    decoration: BoxDecoration(
                                      color: vals[i] == 0
                                          ? AdminColors.hairline
                                          : (sel == i ? AdminColors.amber : AdminColors.teal),
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
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

  // Antigüedad de un pendiente (cuánto lleva esperando revisión).
  String _ageLabel(AppLocalizations l, Object? createdAt) {
    final dt = DateTime.tryParse('$createdAt');
    if (dt == null) return '—';
    final diff = DateTime.now().difference(dt);
    if (diff.inDays >= 1) return '${diff.inDays}d';
    if (diff.inHours >= 1) return '${diff.inHours}h';
    return l.t('adm_age_now');
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
                    Text(
                        '⚠ ${l.t('admin_ch_suspicious')}'
                        '${status == 'pending' ? ' · ⏱ ${_ageLabel(l, c['created_at'])}' : ''}',
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
            else if (status == 'pending') ...[
              // Pendiente de decisión (sospechoso): aceptar o rechazar aquí mismo.
              _tileAction(Icons.check, AdminColors.teal,
                  () => _review(c['id'] as String, 'reward')),
              const SizedBox(width: 6),
              _tileAction(Icons.block, AdminColors.red,
                  () => _rejectWithReason(c['id'] as String)),
            ] else ...[
              AdminTag(l.t('admin_ch_achieved'),
                  fg: AdminColors.teal, bg: AdminColors.tealBg),
              const SizedBox(width: 6),
              _tileAction(Icons.block, AdminColors.red,
                  () => _rejectWithReason(c['id'] as String)),
            ],
          ],
        ),
      ),
    );
  }

  // Botón cuadrado de acción en una fila de reto (aceptar / rechazar).
  Widget _tileAction(IconData icon, Color color, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            border: Border.all(color: color.withValues(alpha: .55)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 15, color: color),
        ),
      );

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
    final source = r['source'] as String? ?? 'reading';
    final isTrip = source == 'transaction';
    final isVehicle = source == 'vehicle';
    final km = (r['km'] as num?)?.toInt() ?? 0;
    final at = DateTime.tryParse((r['at'] as String?) ?? '');
    final plate = (r['plate'] as String?) ?? '—';
    final srcLabel = isVehicle
        ? l.t('adm_km_src_vehicle')
        : (isTrip ? l.t('adm_km_src_trip') : l.t('adm_km_src_reading'));
    final srcFg = isVehicle ? AdminColors.purple : (isTrip ? AdminColors.amber : AdminColors.blue);
    final srcBg = isVehicle ? AdminColors.purpleBg : (isTrip ? AdminColors.amberBg : AdminColors.blueBg);
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
              AdminTag(srcLabel, fg: srcFg, bg: srcBg),
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
              if (isVehicle) {
                await _service.adminCorrectVehicleOdometer(id, newKm);
              } else if (isTrip) {
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
        // El km inicial del vehículo no se borra (solo se corrige).
        if (isVehicle)
          const SizedBox(width: 48)
        else
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
