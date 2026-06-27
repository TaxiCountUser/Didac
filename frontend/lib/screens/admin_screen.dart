import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import 'admin_company_screen.dart';
import 'admin_incident_chat_screen.dart';

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
  late final TabController _tabs = TabController(length: 3, vsync: this);

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
        children: const [_CompaniesTab(), _IncidentsTab(), _ChallengesTab()],
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
    return Card(
      child: ListTile(
        leading: Icon(
          kind == 'app' ? Icons.bug_report : Icons.note_alt,
          color: kind == 'app' ? Colors.deepPurple : Colors.blueGrey,
        ),
        title: Text(body, maxLines: 3, overflow: TextOverflow.ellipsis),
        subtitle: Text('$company · $author'),
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
  late Future<List<Map<String, dynamic>>> _future = _service.adminChallenges();

  void _reload() => setState(() => _future = _service.adminChallenges());

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

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return FutureBuilder<List<Map<String, dynamic>>>(
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
          return Center(child: Text(l.t('admin_no_challenges')));
        }
        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: list.length,
            itemBuilder: (context, i) => _claimTile(l, list[i]),
          ),
        );
      },
    );
  }

  Widget _claimTile(AppLocalizations l, Map<String, dynamic> c) {
    final challenge = (c['challenge'] as String?) ?? '';
    final isKm = challenge == 'km_100k';
    final isDays = challenge == 'days_300';
    final value = (c['metric_value'] as num?)?.toDouble() ?? 0;
    final days = (c['active_days'] as num?)?.toInt() ?? 0;
    final status = (c['status'] as String?) ?? 'pending';
    final suspicious = c['suspicious'] == true;
    final driver = ((c['users'] as Map?)?['name'] as String?)
        ?? ((c['users'] as Map?)?['email'] as String?) ?? '—';
    final company = ((c['tenants'] as Map?)?['name'] as String?) ?? '—';
    final pending = status == 'pending';
    final unit = isKm ? 'km' : (isDays ? l.t('ch_days_unit') : '€');
    final title = isKm ? l.t('ch_km_title') : (isDays ? l.t('ch_days_title') : l.t('ch_money_title'));
    final icon = isKm ? Icons.speed : (isDays ? Icons.calendar_today : Icons.euro);
    return Card(
      child: ListTile(
        leading: Icon(icon, color: Colors.amber.shade800),
        title: Text('$title · $driver'),
        subtitle: Text('$company\n'
            '${value.toStringAsFixed(0)} $unit · ${l.t('ch_days_progress', {'n': '$days', 'min': '300'})}'
            '${suspicious ? '\n⚠️ ${l.t('admin_ch_suspicious')}' : ''}'),
        isThreeLine: true,
        trailing: pending
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: l.t('admin_ch_reward'),
                    icon: const Icon(Icons.card_giftcard, color: Colors.green),
                    onPressed: () => _review(c['id'] as String, 'reward'),
                  ),
                  IconButton(
                    tooltip: l.t('admin_ch_reject'),
                    icon: const Icon(Icons.cancel, color: Colors.red),
                    onPressed: () => _review(c['id'] as String, 'reject'),
                  ),
                ],
              )
            : Chip(
                label: Text(status == 'rewarded' ? l.t('admin_ch_rewarded') : l.t('admin_ch_rejected'),
                    style: const TextStyle(fontSize: 11)),
                backgroundColor: status == 'rewarded' ? Colors.green.shade100 : Colors.grey.shade300,
              ),
      ),
    );
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
