import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import 'admin_company_screen.dart';
import 'admin_incident_chat_screen.dart';
import 'admin_referrals_tab.dart';

/// Panel de administrador de plataforma: ve TODAS las empresas y todas las
/// incidencias, las resuelve, y puede nombrar a otros administradores.
/// Solo accesible si el perfil tiene is_admin = true.
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> with SingleTickerProviderStateMixin {
  final _service = DataService();
  late final TabController _tabs = TabController(length: 4, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.t('admin_title')),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: [
            Tab(text: l.t('admin_companies')),
            Tab(text: l.t('admin_incidents')),
            Tab(text: l.t('admin_challenges')),
            Tab(text: l.t('adm_ref_tab')),
          ],
        ),
        actions: [
          IconButton(
            tooltip: l.t('admin_add_admin'),
            icon: const Icon(Icons.admin_panel_settings),
            onPressed: _makeAdminDialog,
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [_CompaniesTab(), _IncidentsTab(), _ChallengesTab(), ReferralsTab()],
      ),
    );
  }

  // Gestión de administradores: lista los actuales (quitar) y permite añadir.
  Future<void> _makeAdminDialog() async {
    final l = context.l10n;
    final ctrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        Future<List<Map<String, dynamic>>> future = _service.adminListAdmins();
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            void reload() => setLocal(() => future = _service.adminListAdmins());
            Future<void> act(Future<void> Function() fn, String okMsg) async {
              try {
                await fn();
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(okMsg)));
                }
                reload();
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                      content: Text('${l.t('error')}: ${e.toString().replaceFirst('Exception: ', '')}')));
                }
              }
            }

            return AlertDialog(
              title: Text(l.t('admin_manage_title')),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.t('admin_current'), style: Theme.of(ctx).textTheme.bodySmall),
                    const SizedBox(height: 4),
                    Flexible(
                      child: FutureBuilder<List<Map<String, dynamic>>>(
                        future: future,
                        builder: (ctx, snap) {
                          if (snap.connectionState != ConnectionState.done) {
                            return const Padding(
                                padding: EdgeInsets.all(12),
                                child: Center(child: CircularProgressIndicator()));
                          }
                          final admins = snap.data ?? [];
                          if (admins.isEmpty) return Text(l.t('admin_no_admins'));
                          return ListView(
                            shrinkWrap: true,
                            children: [
                              for (final a in admins)
                                ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(Icons.shield, color: Colors.deepPurple),
                                  title: Text((a['email'] as String?) ?? '—',
                                      overflow: TextOverflow.ellipsis),
                                  trailing: IconButton(
                                    tooltip: l.t('admin_remove_admin'),
                                    icon: const Icon(Icons.person_remove, color: Colors.red),
                                    onPressed: () => act(
                                      () => _service.adminMakeAdmin(a['email'] as String, isAdmin: false),
                                      l.t('admin_removed'),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                    const Divider(),
                    Text(l.t('admin_add_admin'), style: Theme.of(ctx).textTheme.bodySmall),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: ctrl,
                            keyboardType: TextInputType.emailAddress,
                            decoration: InputDecoration(
                              labelText: l.t('admin_email'),
                              hintText: 'correo@ejemplo.com',
                              isDense: true,
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () async {
                            if (ctrl.text.trim().isEmpty) return;
                            await act(() => _service.adminMakeAdmin(ctrl.text.trim()), l.t('admin_added'));
                            ctrl.clear();
                          },
                          child: Text(l.t('admin_add')),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.t('close'))),
              ],
            );
          },
        );
      },
    );
  }
}

class _CompaniesTab extends StatefulWidget {
  const _CompaniesTab();
  @override
  State<_CompaniesTab> createState() => _CompaniesTabState();
}

class _CompaniesTabState extends State<_CompaniesTab> {
  final _service = DataService();
  late Future<Map<String, dynamic>> _future = _service.adminOverview();

  void _reload() => setState(() => _future = _service.adminOverview());

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return FutureBuilder<Map<String, dynamic>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return _ErrorRetry(error: '${snap.error}', onRetry: _reload);
        }
        final data = snap.data ?? {};
        final totals = (data['totals'] as Map?)?.cast<String, dynamic>() ?? {};
        final tenants = ((data['tenants'] as List?) ?? []).cast<Map<String, dynamic>>();
        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Card(
                color: Colors.amber.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _Stat(label: l.t('admin_companies'), value: '${totals['tenants'] ?? 0}'),
                      _Stat(label: l.t('admin_users'), value: '${totals['users'] ?? 0}'),
                      _Stat(label: l.t('admin_open'), value: '${totals['open_incidents'] ?? 0}'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              for (final t in tenants) _companyTile(l, t),
            ],
          ),
        );
      },
    );
  }

  Widget _companyTile(AppLocalizations l, Map<String, dynamic> t) {
    final name = (t['name'] as String?) ?? '—';
    final solo = t['solo'] == true;
    final status = (t['subscription_status'] as String?) ?? 'inactive';
    final users = t['users_count'] ?? 0;
    final open = t['open_incidents'] ?? 0;
    return Card(
      child: ListTile(
        leading: Icon(solo ? Icons.person_pin_circle : Icons.business,
            color: solo ? Colors.teal : Colors.amber.shade800),
        title: Text(name),
        subtitle: Text('${l.t('admin_users')}: $users · ${l.t('admin_open')}: $open'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Chip(
              label: Text(adminStatusLabel(l, status), style: const TextStyle(fontSize: 11)),
              backgroundColor: (status == 'active')
                  ? Colors.green.shade100
                  : (status == 'trialing' ? Colors.blue.shade100 : Colors.red.shade100),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: () async {
          await Navigator.of(context).push<bool>(MaterialPageRoute(
            builder: (_) => AdminCompanyScreen(
              tenantId: t['id'] as String,
              tenantName: name,
            ),
          ));
          _reload(); // refresca por si cambió/eliminó algo
        },
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
        SwitchListTile(
          value: _onlyOpen,
          onChanged: (v) => setState(() {
            _onlyOpen = v;
            _future = _load();
          }),
          title: Text(l.t('admin_only_open')),
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
    return Card(
      child: ListTile(
        leading: Icon(
          kind == 'app' ? Icons.bug_report : Icons.note_alt,
          color: kind == 'app' ? Colors.deepPurple : Colors.blueGrey,
        ),
        title: Text(body, maxLines: 3, overflow: TextOverflow.ellipsis),
        subtitle: Text('$company · $author${hidden ? ' · 🗑️ ${l.t('admin_inc_hidden')}' : ''}'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: resolved ? l.t('admin_reopen') : l.t('admin_resolve'),
              icon: Icon(resolved ? Icons.replay : Icons.check_circle,
                  color: resolved ? Colors.orange : Colors.green),
              onPressed: () => _setStatus(inc['id'] as String, resolved ? 'abierta' : 'resuelta'),
            ),
            const Icon(Icons.chat_bubble_outline, size: 18),
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
    return Wrap(spacing: 12, runSpacing: 12, children: [
      _kpi(Icons.emoji_events, l.t('adm_ch_kpi_completed'), '${n('total_completed')}', Colors.amber.shade800),
      _kpi(Icons.groups, l.t('adm_ch_kpi_drivers'), '${n('drivers_with_challenge')}%', Colors.blue),
      _kpi(Icons.trending_up, l.t('adm_ch_kpi_avglevel'), '${n('avg_level')}', Colors.teal),
      _kpi(Icons.card_giftcard, l.t('adm_ch_kpi_days'), '${n('days_awarded')}', Colors.green),
      _kpi(Icons.hourglass_bottom, l.t('adm_ch_kpi_pending'), '${n('pending_approvals')}', Colors.deepOrange),
    ]);
  }

  Widget _kpi(IconData icon, String label, String value, Color color) => Container(
        width: 150, padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 8),
          Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ]),
      );

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
              _maxVal(byLevel.values), Colors.indigo),
      ]),
      const SizedBox(height: 12),
      _chartCard(l.t('adm_ch_chart_monthly'), [
        for (final e in byMonth.entries)
          _bar(e.key.substring(2), e.value, _maxVal(byMonth.values), Colors.teal),
      ]),
      const SizedBox(height: 12),
      _chartCard(l.t('adm_ch_chart_top'), [
        if (top.isEmpty) Text(l.t('admin_no_challenges'), style: const TextStyle(color: Colors.grey, fontSize: 12)),
        for (final e in top.take(10))
          _bar(e.key, e.value, top.first.value, Colors.amber.shade800),
      ]),
    ]);
  }

  int _maxVal(Iterable<int> v) => v.isEmpty ? 1 : v.reduce((a, b) => a > b ? a : b);

  Widget _chartCard(String title, List<Widget> bars) => Card(
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
                    color: Colors.grey.shade200, borderRadius: BorderRadius.circular(4))),
                Container(height: 16, width: cons.maxWidth * frac,
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4))),
              ]);
            }),
          ),
          SizedBox(width: 34, child: Text('$value', textAlign: TextAlign.right, style: const TextStyle(fontSize: 11))),
        ]),
      );

  // ── Filtros + acceso a trimestrales ────────────────────────────────────────
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
          OutlinedButton.icon(onPressed: _openQuarterly, icon: const Icon(Icons.calendar_view_month, size: 18),
              label: Text(l.t('adm_ch_quarterly'))),
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
    return Card(
      child: ListTile(
        onTap: () => _openDetail(c['id'] as String),
        leading: Icon(icon, color: Colors.amber.shade800),
        title: Text('$title · ${l.t('ch_level', {'n': '$level'})} · $driver'),
        subtitle: Text('$company\n'
            '${l.t('admin_ch_goal')}: ${target.toStringAsFixed(0)} $unit · ${l.t('ch_days_progress', {'n': '$days', 'min': '300'})}'
            '${suspicious ? '\n⚠️ ${l.t('admin_ch_suspicious')}' : ''}'),
        isThreeLine: true,
        trailing: rejected
            ? Chip(
                label: Text(l.t('admin_ch_rejected'), style: const TextStyle(fontSize: 11)),
                backgroundColor: Colors.grey.shade300,
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Chip(
                    label: Text(l.t('admin_ch_achieved'), style: const TextStyle(fontSize: 11)),
                    backgroundColor: Colors.green.shade100,
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    tooltip: l.t('admin_ch_fraud'),
                    icon: const Icon(Icons.block, color: Colors.red),
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

  // ── Recompensas trimestrales ───────────────────────────────────────────────
  Future<void> _openQuarterly() async {
    final l = context.l10n;
    Map<String, dynamic>? data;
    try {
      data = await _service.adminChallengeQuarterly();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
      return;
    }
    if (!mounted) return;
    final rows = ((data['metrics'] as List?) ?? []).cast<Map<String, dynamic>>();
    final df = DateFormat('dd/MM/yyyy');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('adm_ch_quarterly')),
        content: SizedBox(
          width: 560,
          child: rows.isEmpty
              ? Text(l.t('admin_no_challenges'))
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: [
                      DataColumn(label: Text(l.t('adm_ch_col_quarter'))),
                      DataColumn(label: Text(l.t('adm_ch_col_company'))),
                      DataColumn(label: Text(l.t('adm_ch_col_rate'))),
                      DataColumn(label: Text(l.t('adm_ch_col_reward'))),
                      DataColumn(label: Text(l.t('adm_ch_col_status'))),
                      const DataColumn(label: Text('')),
                    ],
                    rows: rows.map((r) {
                      final rate = (r['completion_rate'] as num?)?.toDouble() ?? 0;
                      final days = (r['reward_days_awarded'] as num?)?.toInt() ?? 0;
                      final processed = DateTime.tryParse((r['processed_at'] as String?) ?? '');
                      return DataRow(cells: [
                        DataCell(Text('Q${r['quarter']} ${r['year']}')),
                        DataCell(Text(((r['tenant'] as Map?)?['name'] as String?) ?? '—')),
                        DataCell(Text('${rate.toStringAsFixed(1)}%')),
                        DataCell(Text('$days')),
                        DataCell(Text(processed != null ? df.format(processed) : (r['status'] as String? ?? '—'))),
                        DataCell(IconButton(
                          icon: const Icon(Icons.edit, size: 18),
                          tooltip: l.t('adm_ch_q_adjust'),
                          onPressed: () { Navigator.pop(ctx); _adjustQuarterly(r['id'] as String, days); },
                        )),
                      ]);
                    }).toList(),
                  ),
                ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.t('close')))],
      ),
    );
  }

  Future<void> _adjustQuarterly(String id, int currentDays) async {
    final l = context.l10n;
    final daysCtrl = TextEditingController(text: '$currentDays');
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('adm_ch_q_adjust')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: daysCtrl, keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: l.t('adm_ch_q_days'))),
          TextField(controller: reasonCtrl, decoration: InputDecoration(labelText: l.t('adm_ch_q_reason'))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('adm_ref_config_save'))),
        ],
      ),
    );
    if (ok != true) return;
    final days = int.tryParse(daysCtrl.text.trim());
    final reason = reasonCtrl.text.trim();
    if (days == null || reason.isEmpty) return;
    try {
      await _service.adminChallengeQuarterlyAdjust(id, days, reason);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('adm_ch_adjusted'))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value, style: Theme.of(context).textTheme.headlineSmall),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
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
