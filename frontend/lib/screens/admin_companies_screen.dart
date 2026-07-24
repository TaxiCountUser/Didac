import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import 'admin_company_detail_screen.dart';
import 'admin_theme.dart';

/// Módulo Empresas del panel: lista con buscador global (empresa, email,
/// matrícula — resuelto en el backend), filtros de estado, recuento y orden.
/// Toca una empresa para abrir su ficha (AdminCompanyDetailScreen).
class AdminCompaniesScreen extends StatefulWidget {
  const AdminCompaniesScreen({super.key, this.initialFilter});

  /// Filtro inicial opcional ('paying'|'trial'|'risk'), para llegar desde las
  /// KPI del panel ya filtrado (nivel B). Null = todas.
  final String? initialFilter;

  @override
  State<AdminCompaniesScreen> createState() => _AdminCompaniesScreenState();
}

enum _Filter { all, paying, trial, risk }

enum _Sort { recent, name, status }

class _AdminCompaniesScreenState extends State<AdminCompaniesScreen> {
  final _service = DataService();
  final _searchCtrl = TextEditingController();
  late Future<Map<String, dynamic>> _future = _service.adminOverview();

  _Filter _filter = _Filter.all;
  _Sort _sort = _Sort.recent;
  String _query = '';
  Timer? _debounce;
  // tenant_id -> motivo del match remoto (email/matrícula) del buscador global.
  Map<String, String> _remoteMatches = {};

  void _reload() => setState(() => _future = _service.adminOverview());

  @override
  void initState() {
    super.initState();
    _filter = switch (widget.initialFilter) {
      'paying' => _Filter.paying,
      'trial' => _Filter.trial,
      'risk' => _Filter.risk,
      _ => _Filter.all,
    };
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onQuery(String v) {
    setState(() => _query = v.trim());
    _debounce?.cancel();
    if (_query.length < 2) {
      setState(() => _remoteMatches = {});
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final results = await _service.adminSearch(_query);
        if (!mounted) return;
        setState(() => _remoteMatches = {
              for (final r in results)
                r['tenant_id'] as String: (r['reason'] as String?) ?? '',
            });
      } catch (_) {/* best-effort: queda el filtro local */}
    });
  }

  bool _isTrial(Map<String, dynamic> t) {
    final s = t['subscription_status'] as String?;
    final te = DateTime.tryParse('${t['trial_ends_at']}');
    return s != 'active' && s != 'past_due' && te != null && te.isAfter(DateTime.now());
  }

  bool _isRisk(Map<String, dynamic> t) {
    final s = t['subscription_status'] as String?;
    final te = DateTime.tryParse('${t['trial_ends_at']}');
    return s == 'past_due' || s == 'canceled' ||
        (te != null && !te.isAfter(DateTime.now()) && s != 'active');
  }

  bool _matchesFilter(Map<String, dynamic> t) {
    switch (_filter) {
      case _Filter.all:
        return true;
      case _Filter.paying:
        return t['subscription_status'] == 'active';
      case _Filter.trial:
        return _isTrial(t);
      case _Filter.risk:
        return _isRisk(t);
    }
  }

  bool _matchesQuery(Map<String, dynamic> t) {
    if (_query.isEmpty) return true;
    final name = ((t['name'] as String?) ?? '').toLowerCase();
    if (name.contains(_query.toLowerCase())) return true;
    return _remoteMatches.containsKey(t['id']);
  }

  int _statusRank(String? s) => switch (s) {
        'active' => 0,
        'past_due' => 1,
        'trialing' => 2,
        'canceled' => 3,
        _ => 4,
      };

  void _sortList(List<Map<String, dynamic>> rows) {
    switch (_sort) {
      case _Sort.recent:
        rows.sort((a, b) => '${b['created_at']}'.compareTo('${a['created_at']}'));
      case _Sort.name:
        rows.sort((a, b) => ('${a['name']}').toLowerCase()
            .compareTo(('${b['name']}').toLowerCase()));
      case _Sort.status:
        rows.sort((a, b) {
          final r = _statusRank(a['subscription_status'] as String?)
              .compareTo(_statusRank(b['subscription_status'] as String?));
          return r != 0 ? r : '${b['created_at']}'.compareTo('${a['created_at']}');
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Theme(
      data: adminDarkTheme(),
      child: Scaffold(
        backgroundColor: AdminColors.bg,
        appBar: adminAppBar(l.t('admin_companies'), actions: [
          IconButton(
              tooltip: l.t('refresh'),
              icon: const Icon(Icons.refresh, size: 20, color: AdminColors.secondary),
              onPressed: _reload),
        ]),
        body: FutureBuilder<Map<String, dynamic>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(
                  child: CircularProgressIndicator(color: AdminColors.teal));
            }
            if (snap.hasError) {
              return Center(
                  child: Text('${snap.error}',
                      style: const TextStyle(color: AdminColors.red, fontSize: 13)));
            }
            final tenants = (((snap.data ?? {})['tenants'] as List?) ?? [])
                .cast<Map<String, dynamic>>();
            final visible = tenants
                .where(_matchesFilter)
                .where(_matchesQuery)
                .toList();
            _sortList(visible);
            final ridesTotal = ((((snap.data ?? const {})['kpis'] as Map?)
                ?? const {})['rides_total'] as num?)?.toInt() ?? 0;
            final payingN = tenants.where((t) => t['subscription_status'] == 'active').length;
            final trialN = tenants.where(_isTrial).length;
            final riskN = tenants.where(_isRisk).length;
            return adminConstrained(Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: adminSearchField(
                    fieldKey: const Key('admin_company_search'),
                    controller: _searchCtrl,
                    hint: l.t('adm_co_search_hint'),
                    onChanged: _onQuery,
                    hasQuery: _query.isNotEmpty,
                    onClear: () {
                      _searchCtrl.clear();
                      _onQuery('');
                    },
                  ),
                ),
                // Cabecera de KPI pertinentes (a la vez filtros): total · pagament ·
                // prova · risc con recuento, + carreres totals. El filtro activo se
                // resalta al tocar la tarjeta.
                SizedBox(
                  height: 56,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      _kpiCard(l.t('adm_co_all'), '${tenants.length}', AdminColors.purple, filter: _Filter.all),
                      _kpiCard(l.t('adm_co_paying'), '$payingN', AdminColors.teal, filter: _Filter.paying),
                      _kpiCard(l.t('adm_co_trial'), '$trialN', AdminColors.amber, filter: _Filter.trial),
                      _kpiCard(l.t('adm_co_risk'), '$riskN', AdminColors.red, filter: _Filter.risk),
                      _kpiCard(l.t('adm_kpi_rides'), '$ridesTotal', AdminColors.blue),
                    ],
                  ),
                ),
                // Recuento + orden.
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 12, 6),
                  child: Row(
                    children: [
                      Text(l.t('adm_co_count', {'n': '${visible.length}'}),
                          style: const TextStyle(
                              fontSize: 11, color: AdminColors.secondary)),
                      const Spacer(),
                      _sortButton(l),
                    ],
                  ),
                ),
                Expanded(
                  child: visible.isEmpty
                      ? Center(
                          child: Text(l.t('adm_no_results'),
                              style: const TextStyle(
                                  fontSize: 13, color: AdminColors.muted)))
                      : RefreshIndicator(
                          color: AdminColors.teal,
                          backgroundColor: AdminColors.card,
                          onRefresh: () async => _reload(),
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                            children: [
                              adminRowsCard(
                                  [for (final t in visible) _companyRow(l, t)]),
                            ],
                          ),
                        ),
                ),
              ],
            ));
          },
        ),
      ),
    );
  }

  // Tarjeta KPI de Empresas: valor + etiqueta. Si lleva filter, filtra la lista
  // y se resalta cuando está seleccionada; 'carreres totals' va sin filter.
  Widget _kpiCard(String label, String value, Color color, {_Filter? filter}) {
    final selected = filter != null && _filter == filter;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: filter == null ? null : () => setState(() => _filter = filter),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 104,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: .14) : AdminColors.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: color.withValues(alpha: selected ? .9 : .3),
                width: selected ? 1.4 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(value,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: color)),
              const SizedBox(height: 1),
              Text(label,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: AdminColors.secondary)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sortButton(AppLocalizations l) {
    String label(_Sort s) => switch (s) {
          _Sort.recent => l.t('adm_co_sort_recent'),
          _Sort.name => l.t('adm_co_sort_name'),
          _Sort.status => l.t('adm_co_sort_status'),
        };
    return PopupMenuButton<_Sort>(
      initialValue: _sort,
      tooltip: l.t('adm_co_sort'),
      onSelected: (s) => setState(() => _sort = s),
      itemBuilder: (ctx) => [
        for (final s in _Sort.values)
          PopupMenuItem(value: s, child: Text(label(s))),
      ],
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.swap_vert, size: 15, color: AdminColors.secondary),
        const SizedBox(width: 4),
        Text(label(_sort),
            style: const TextStyle(fontSize: 11, color: AdminColors.secondary)),
      ]),
    );
  }

  Widget _companyRow(AppLocalizations l, Map<String, dynamic> t) {
    final name = (t['name'] as String?) ?? '—';
    final status = t['subscription_status'] as String?;
    final trialEnds = DateTime.tryParse('${t['trial_ends_at']}');
    final trialLeft = (trialEnds != null && trialEnds.isAfter(DateTime.now()))
        ? trialEnds.difference(DateTime.now()).inDays + 1
        : 0;
    final users = (t['users_count'] as num?)?.toInt() ?? 0;
    final openInc = (t['open_incidents'] as num?)?.toInt() ?? 0;
    final match = _remoteMatches[t['id']];

    return AdminListRow(
      leading: AdminInitialsAvatar(name: name),
      title: name,
      titleTrailing: openInc > 0
          ? const Icon(Icons.mark_chat_unread, size: 12, color: AdminColors.amber)
          : null,
      subtitle: '$users ${l.t('admin_users').toLowerCase()}'
          '${openInc > 0 ? ' · $openInc ${l.t('admin_open').toLowerCase()}' : ''}',
      note: (match != null && match.isNotEmpty)
          ? l.t('adm_co_match', {'m': match})
          : null,
      trailing: AdminStatusChip(status: status, trialDaysLeft: trialLeft),
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => AdminCompanyDetailScreen(
              tenantId: t['id'] as String, tenantName: name),
        ));
        _reload();
      },
    );
  }
}
