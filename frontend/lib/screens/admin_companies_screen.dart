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
  const AdminCompaniesScreen({super.key});

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

  bool _matchesFilter(Map<String, dynamic> t) {
    final s = t['subscription_status'] as String?;
    final trialEnds = DateTime.tryParse('${t['trial_ends_at']}');
    final inTrial = s != 'active' && s != 'past_due' &&
        trialEnds != null && trialEnds.isAfter(DateTime.now());
    switch (_filter) {
      case _Filter.all:
        return true;
      case _Filter.paying:
        return s == 'active';
      case _Filter.trial:
        return inTrial;
      case _Filter.risk:
        return s == 'past_due' || s == 'canceled' ||
            (trialEnds != null && !trialEnds.isAfter(DateTime.now()) &&
                s != 'active');
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
                SizedBox(
                  height: 34,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      _pill(l.t('adm_co_all'), _Filter.all, AdminColors.purple),
                      _pill(l.t('adm_co_paying'), _Filter.paying, AdminColors.teal),
                      _pill(l.t('adm_co_trial'), _Filter.trial, AdminColors.amber),
                      _pill(l.t('adm_co_risk'), _Filter.risk, AdminColors.red),
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

  Widget _pill(String label, _Filter f, Color color) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: AdminPill(
            label: label,
            selected: _filter == f,
            color: color,
            onTap: () => setState(() => _filter = f)),
      );

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
