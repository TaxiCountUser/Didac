import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';

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
  late final TabController _tabs = TabController(length: 2, vsync: this);

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
          tabs: [
            Tab(text: l.t('admin_companies')),
            Tab(text: l.t('admin_incidents')),
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
        children: const [_CompaniesTab(), _IncidentsTab()],
      ),
    );
  }

  Future<void> _makeAdminDialog() async {
    final l = context.l10n;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('admin_add_admin')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(
            labelText: l.t('admin_email'),
            hintText: 'correo@ejemplo.com',
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('save'))),
        ],
      ),
    );
    if (ok != true || ctrl.text.trim().isEmpty) return;
    try {
      await _service.adminMakeAdmin(ctrl.text.trim());
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.t('admin_added'))));
      }
    } catch (e) {
      if (mounted) {
        final msg = e.toString().replaceFirst('Exception: ', '');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l.t('error')}: $msg')));
      }
    }
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
        trailing: Chip(
          label: Text(status, style: const TextStyle(fontSize: 11)),
          backgroundColor: (status == 'active')
              ? Colors.green.shade100
              : (status == 'trialing' ? Colors.blue.shade100 : Colors.red.shade100),
        ),
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
        trailing: IconButton(
          tooltip: resolved ? l.t('admin_reopen') : l.t('admin_resolve'),
          icon: Icon(resolved ? Icons.replay : Icons.check_circle,
              color: resolved ? Colors.orange : Colors.green),
          onPressed: () => _setStatus(inc['id'] as String, resolved ? 'abierta' : 'resuelta'),
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
