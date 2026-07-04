import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import 'admin_theme.dart';

/// Loop #5 — Pestaña "Referidos" del panel de Super Admin.
/// KPIs + tabla con filtros y paginación + detalle (bloquear/desbloquear) +
/// configuración de hitos. Solo accesible para superadmin (la pantalla padre
/// ya está protegida por is_admin).
class ReferralsTab extends StatefulWidget {
  const ReferralsTab({super.key});

  @override
  State<ReferralsTab> createState() => _ReferralsTabState();
}

class _ReferralsTabState extends State<ReferralsTab> {
  final _service = DataService();
  final _searchCtrl = TextEditingController();

  Map<String, dynamic>? _kpis;
  List<Map<String, dynamic>> _rows = [];
  int _total = 0;
  int _offset = 0;
  int _pageSize = 25;
  String _status = '';
  String _channel = '';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() { _loading = true; _error = null; });
    try {
      final kpis = await _service.adminReferralKpis();
      final list = await _service.adminReferralList(
        status: _status, channel: _channel, search: _searchCtrl.text.trim(),
        limit: _pageSize, offset: _offset,
      );
      if (!mounted) return;
      setState(() {
        _kpis = kpis;
        _rows = ((list['referrals'] as List?) ?? []).cast<Map<String, dynamic>>();
        _total = (list['total'] as num?)?.toInt() ?? _rows.length;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString().replaceFirst('Exception: ', ''); _loading = false; });
    }
  }

  void _applyFilters() { _offset = 0; _reload(); }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _kpisRow(l),
          const SizedBox(height: 16),
          _filtersBar(l),
          const SizedBox(height: 12),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(12),
                child: Text('${l.t('error')}: $_error', style: const TextStyle(color: Colors.red)))
          else if (_loading)
            const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
          else ...[
            _table(l),
            const SizedBox(height: 12),
            _pagination(l),
          ],
        ],
      ),
    );
  }

  // ── KPIs ────────────────────────────────────────────────────────────────
  Widget _kpisRow(AppLocalizations l) {
    final k = _kpis ?? {};
    num n(String key) => (k[key] as num?) ?? 0;
    final conv = (n('conversion_rate') * 100).toStringAsFixed(1);
    return Wrap(
      spacing: 8, runSpacing: 8,
      children: [
        _kpiCard(Icons.group, l.t('adm_ref_kpi_total'), '${n('total_referrals')}', AdminColors.pink),
        _kpiCard(Icons.trending_up, l.t('adm_ref_kpi_conv'), '$conv%', AdminColors.teal),
        _kpiCard(Icons.emoji_events, l.t('adm_ref_kpi_milestones'), '${n('milestones_achieved')}', AdminColors.amber),
        _kpiCard(Icons.card_giftcard, l.t('adm_ref_kpi_days'), '${n('days_awarded')}', AdminColors.blue),
        _kpiCard(Icons.warning_amber, l.t('adm_ref_kpi_fraud'), '${n('fraud_alerts')}', AdminColors.red),
      ],
    );
  }

  Widget _kpiCard(IconData icon, String label, String value, Color color) =>
      AdminKpiTile(width: 150, icon: icon, label: label, value: value, color: color);

  // ── Filtros (rediseño N: buscador + píldoras de estado y canal) ────────────
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 17, color: AdminColors.muted),
                hintText: l.t('adm_ref_search'),
              ),
              onSubmitted: (_) => _applyFilters(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: l.t('adm_ref_export_csv'),
            icon: const Icon(Icons.download, size: 19, color: AdminColors.secondary),
            onPressed: _exportCsv,
          ),
        ]),
        const SizedBox(height: 8),
        pills([
          ('', l.t('adm_ref_all')),
          ('pending', l.t('ref_status_pending')),
          ('valid', l.t('ref_status_valid')),
          ('reverted', l.t('ref_status_reverted')),
          ('rejected', l.t('ref_status_rejected')),
        ], _status, AdminColors.pink,
            (v) { setState(() => _status = v); _applyFilters(); }),
        const SizedBox(height: 6),
        pills([
          ('', l.t('adm_ref_channel')),
          ('whatsapp', 'WhatsApp'),
          ('email', 'Email'),
          ('sms', 'SMS'),
          ('link', 'Link'),
        ], _channel, AdminColors.blue,
            (v) { setState(() => _channel = v); _applyFilters(); }),
      ],
    );
  }

  // ── Lista (rediseño N: filas oscuras, legible también en móvil) ────────────
  Widget _table(AppLocalizations l) {
    if (_rows.isEmpty) {
      return Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(l.t('adm_ref_none'))));
    }
    final df = DateFormat('dd/MM/yyyy');
    return Container(
      decoration: adminCardBox(),
      child: Column(
        children: [
          for (var i = 0; i < _rows.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: AdminColors.hairline),
            _referralRow(l, _rows[i], df),
          ],
        ],
      ),
    );
  }

  Widget _referralRow(AppLocalizations l, Map<String, dynamic> r, DateFormat df) {
    final referrer = (r['referrer'] as Map?) ?? {};
    final referred = (r['referred'] as Map?) ?? {};
    final tenant = (r['tenant'] as Map?) ?? {};
    final status = (r['status'] as String?) ?? '';
    final alerts = ((r['alerts'] as List?) ?? []);
    final created = DateTime.tryParse((r['created_at'] as String?) ?? '');
    return InkWell(
      onTap: () => _openDetail(r['id'] as String),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            AdminInitialsAvatar(
                name: (tenant['name'] as String?) ?? '—',
                color: AdminColors.pink, bg: AdminColors.redBg, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text((tenant['name'] as String?) ?? '—',
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w500,
                              color: AdminColors.text)),
                    ),
                    if (alerts.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      const Icon(Icons.warning_amber,
                          size: 13, color: AdminColors.amber),
                    ],
                  ]),
                  Text(
                    '${(referrer['email'] as String?) ?? '—'} → ${(referred['email'] as String?) ?? '—'}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: AdminColors.muted),
                  ),
                  Text(created != null ? df.format(created) : '—',
                      style: const TextStyle(
                          fontSize: 9, color: AdminColors.muted)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _statusChip(l, status),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, size: 15, color: AdminColors.muted),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(AppLocalizations l, String status) {
    final color = switch (status) {
      'valid' => AdminColors.teal,
      'pending' => AdminColors.amber,
      'reverted' || 'rejected' => AdminColors.red,
      _ => AdminColors.gray,
    };
    return AdminTag(l.t('ref_status_$status'),
        fg: color, bg: color.withValues(alpha: .16));
  }

  // ── Paginación ───────────────────────────────────────────────────────────
  Widget _pagination(AppLocalizations l) {
    final from = _total == 0 ? 0 : _offset + 1;
    final to = (_offset + _pageSize).clamp(0, _total);
    return Row(
      children: [
        Text(l.t('adm_ref_page', {'from': '$from', 'to': '$to', 'total': '$_total'})),
        const Spacer(),
        DropdownButton<int>(
          value: _pageSize,
          items: const [25, 50, 100].map((n) => DropdownMenuItem(value: n, child: Text('$n / pág.'))).toList(),
          onChanged: (v) { setState(() { _pageSize = v ?? 25; _offset = 0; }); _reload(); },
        ),
        const SizedBox(width: 8),
        IconButton(
          onPressed: _offset > 0 ? () { setState(() => _offset -= _pageSize); _reload(); } : null,
          icon: const Icon(Icons.chevron_left),
        ),
        IconButton(
          onPressed: (_offset + _pageSize) < _total ? () { setState(() => _offset += _pageSize); _reload(); } : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }

  // ── Exportar CSV (al portapapeles, compatible web+móvil) ───────────────────
  void _exportCsv() {
    final l = context.l10n;
    final buf = StringBuffer('empresa,referidor,invitado,estado,fecha,alertas\n');
    for (final r in _rows) {
      final tenant = ((r['tenant'] as Map?)?['name'] as String?) ?? '';
      final referrer = ((r['referrer'] as Map?)?['email'] as String?) ?? '';
      final referred = ((r['referred'] as Map?)?['email'] as String?) ?? '';
      final status = (r['status'] as String?) ?? '';
      final created = (r['created_at'] as String?) ?? '';
      final alerts = ((r['alerts'] as List?) ?? []).length;
      String q(String s) => '"${s.replaceAll('"', '""')}"';
      buf.writeln([q(tenant), q(referrer), q(referred), q(status), q(created), '$alerts'].join(','));
    }
    Clipboard.setData(ClipboardData(text: buf.toString()));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('adm_ref_csv_copied'))));
  }

  // ── Detalle (modal) ────────────────────────────────────────────────────
  Future<void> _openDetail(String id) async {
    final l = context.l10n;
    Map<String, dynamic>? data;
    try {
      data = await _service.adminReferralDetail(id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
      return;
    }
    if (!mounted) return;
    final ref = (data['referral'] as Map?) ?? {};
    final referrer = (ref['referrer'] as Map?) ?? {};
    final referred = (ref['referred'] as Map?) ?? {};
    final tenant = (ref['tenant'] as Map?) ?? {};
    final fraud = (data['fraud'] as Map?) ?? {};
    final events = ((data['events'] as List?) ?? []).cast<Map<String, dynamic>>();
    final status = (ref['status'] as String?) ?? '';
    final df = DateFormat('dd/MM/yyyy HH:mm');

    await showAdminDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('adm_ref_detail')),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _kv(l.t('adm_ref_col_referrer'), '${referrer['name'] ?? ''} <${referrer['email'] ?? '—'}>'),
                _kv(l.t('adm_ref_col_invited'), '${referred['email'] ?? '—'}'),
                _kv(l.t('adm_ref_col_company'), '${tenant['name'] ?? '—'} · ${tenant['subscription_status'] ?? '—'}'),
                _kv(l.t('adm_ref_col_status'), l.t('ref_status_$status')),
                const Divider(),
                Text(l.t('adm_ref_events'), style: const TextStyle(fontWeight: FontWeight.bold)),
                for (final e in events)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text('• ${e['type']}'
                        '${e['level'] != null ? ' (nivel ${e['level']}, +${e['days']}d)' : ''}'
                        ' — ${DateTime.tryParse((e['at'] as String?) ?? '') != null ? df.format(DateTime.parse(e['at'])) : ''}',
                        style: const TextStyle(fontSize: 12)),
                  ),
                const Divider(),
                Text(l.t('adm_ref_fraud'), style: const TextStyle(fontWeight: FontWeight.bold)),
                _kv('IP', '${fraud['signup_ip'] ?? '—'}'),
                _kv('Device', '${fraud['signup_device_id'] ?? '—'}'),
                _kv(l.t('adm_ref_kpi_fraud'), '${((fraud['alerts'] as List?) ?? []).length}'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.t('close'))),
          if (status == 'rejected' || status == 'reverted')
            FilledButton.tonal(
              onPressed: () async { Navigator.pop(ctx); await _unblock(id); },
              child: Text(l.t('adm_ref_unblock')),
            )
          else
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () async { Navigator.pop(ctx); await _blockWithReason(id); },
              child: Text(l.t('adm_ref_block')),
            ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: RichText(text: TextSpan(
          style: const TextStyle(color: AdminColors.text, fontSize: 13),
          children: [
            TextSpan(text: '$k: ', style: const TextStyle(fontWeight: FontWeight.w600)),
            TextSpan(text: v),
          ],
        )),
      );

  Future<void> _blockWithReason(String id) async {
    final l = context.l10n;
    final ctrl = TextEditingController();
    final reason = await showAdminDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('adm_ref_block')),
        content: TextField(
          controller: ctrl, autofocus: true,
          decoration: InputDecoration(labelText: l.t('adm_ref_block_reason')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text(l.t('adm_ref_block'))),
        ],
      ),
    );
    if (reason == null) return;
    try {
      await _service.adminReferralBlock(id, reason);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('adm_ref_blocked'))));
      _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  Future<void> _unblock(String id) async {
    final l = context.l10n;
    try {
      await _service.adminReferralUnblock(id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('adm_ref_unblocked'))));
      _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

}
