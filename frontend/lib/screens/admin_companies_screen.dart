import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import 'admin_company_detail_screen.dart';
import 'admin_theme.dart';

/// Módulo Empresas del panel rediseñado (Fase 2): lista con buscador global
/// (empresa, email, matrícula — resuelto en el backend) y filtros de estado.
/// Toca una empresa para abrir su ficha oscura (AdminCompanyDetailScreen).
class AdminCompaniesScreen extends StatefulWidget {
  const AdminCompaniesScreen({super.key});

  @override
  State<AdminCompaniesScreen> createState() => _AdminCompaniesScreenState();
}

enum _Filter { all, paying, trial, risk }

class _AdminCompaniesScreenState extends State<AdminCompaniesScreen> {
  final _service = DataService();
  final _searchCtrl = TextEditingController();
  late Future<Map<String, dynamic>> _future = _service.adminOverview();

  _Filter _filter = _Filter.all;
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
    // Búsqueda remota (email, matrícula, usuario) con debounce.
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final results = await _service.adminSearch(_query);
        if (!mounted) return;
        setState(() => _remoteMatches = {
              for (final r in results)
                if ((r['reason'] as String?)?.isNotEmpty == true)
                  r['tenant_id'] as String: r['reason'] as String,
              for (final r in results)
                if ((r['reason'] as String?)?.isEmpty != false)
                  r['tenant_id'] as String: '',
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

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Theme(
      data: adminDarkTheme(),
      child: Scaffold(
        backgroundColor: AdminColors.bg,
        appBar: AppBar(
          backgroundColor: AdminColors.bg,
          foregroundColor: AdminColors.text,
          elevation: 0,
          title: Text(l.t('admin_companies'),
              style: const TextStyle(fontSize: 16, color: AdminColors.text)),
          actions: [
            IconButton(
                tooltip: l.t('refresh'),
                icon: const Icon(Icons.refresh, size: 20, color: AdminColors.secondary),
                onPressed: _reload),
          ],
        ),
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
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: TextField(
                    key: const Key('admin_company_search'),
                    controller: _searchCtrl,
                    onChanged: _onQuery,
                    style: const TextStyle(fontSize: 13, color: AdminColors.text),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: l.t('adm_co_search_hint'),
                      hintStyle: const TextStyle(
                          fontSize: 12, color: AdminColors.muted),
                      prefixIcon: const Icon(Icons.search,
                          size: 17, color: AdminColors.muted),
                      filled: true,
                      fillColor: AdminColors.card,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear,
                                  size: 16, color: AdminColors.muted),
                              onPressed: () {
                                _searchCtrl.clear();
                                _onQuery('');
                              },
                            ),
                    ),
                  ),
                ),
                SizedBox(
                  height: 34,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      _filterChip(l.t('adm_co_all'), _Filter.all, AdminColors.purple),
                      _filterChip(l.t('adm_co_paying'), _Filter.paying, AdminColors.teal),
                      _filterChip(l.t('adm_co_trial'), _Filter.trial, AdminColors.amber),
                      _filterChip(l.t('adm_co_risk'), _Filter.risk, AdminColors.red),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
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
                          child: ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                            itemCount: visible.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 6),
                            itemBuilder: (context, i) =>
                                _companyRow(l, visible[i]),
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _filterChip(String label, _Filter f, Color color) {
    final selected = _filter == f;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        onTap: () => setState(() => _filter = f),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? color : Colors.transparent,
            border: Border.all(
                color: selected ? color : color.withValues(alpha: .35)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? AdminColors.bg : color,
              )),
        ),
      ),
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

    return InkWell(
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => AdminCompanyDetailScreen(
              tenantId: t['id'] as String, tenantName: name),
        ));
        _reload();
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AdminColors.card,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            AdminInitialsAvatar(name: name),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(name,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w500,
                                color: AdminColors.text)),
                      ),
                      if (openInc > 0) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.mark_chat_unread,
                            size: 12, color: AdminColors.amber),
                      ],
                    ],
                  ),
                  Text(
                    '$users ${l.t('admin_users').toLowerCase()}'
                    '${openInc > 0 ? ' · $openInc ${l.t('admin_open').toLowerCase()}' : ''}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(fontSize: 10.5, color: AdminColors.muted),
                  ),
                  if (match != null && match.isNotEmpty)
                    Text(l.t('adm_co_match', {'m': match}),
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 10, color: AdminColors.blue)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            AdminStatusChip(status: status, trialDaysLeft: trialLeft),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, size: 16, color: AdminColors.muted),
          ],
        ),
      ),
    );
  }
}
