import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';

/// Pestaña "Configuración" del panel de admin: edita en un solo sitio los
/// parámetros de RETOS y de REFERIDOS, con etiquetas claras y explicaciones
/// (separado de las estadísticas). Todo se guarda en system_config.
class ConfigTab extends StatefulWidget {
  const ConfigTab({super.key});

  @override
  State<ConfigTab> createState() => _ConfigTabState();
}

class _ConfigTabState extends State<ConfigTab> {
  final _service = DataService();
  Map<String, String> _cfg = {};
  bool _loading = true;
  bool _saving = false;
  String? _error;

  // Controladores por clave (para campos numéricos/de texto).
  final _ctrls = <String, TextEditingController>{};
  // Estado de los switches (booleanos).
  bool _eurosOn = false;
  bool _refOn = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _g(String key, [String def = '']) => _cfg[key] ?? def;

  TextEditingController _c(String key, String value) =>
      _ctrls.putIfAbsent(key, () => TextEditingController(text: value));

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final data = await _service.adminSystemConfig();
      final cfg = <String, String>{};
      ((data['config'] as Map?) ?? {}).forEach((k, v) => cfg['$k'] = '$v');
      if (!mounted) return;
      setState(() {
        _cfg = cfg;
        _eurosOn = _g('challenge_100k_euros_enabled', 'false') == 'true';
        _refOn = _g('referral_enabled', 'true') == 'true';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString().replaceFirst('Exception: ', ''); _loading = false; });
    }
  }

  Future<void> _save() async {
    final l = context.l10n;
    setState(() => _saving = true);
    final changes = <String, String>{};
    // Campos de texto (números).
    _ctrls.forEach((key, ctrl) {
      final v = ctrl.text.trim();
      // El regalo se muestra en €, se guarda en céntimos.
      if (key == 'challenge_seat_credit_cents') {
        final eur = double.tryParse(v.replaceAll(',', '.')) ?? 0;
        changes[key] = '${(eur * 100).round()}';
      } else {
        changes[key] = v;
      }
    });
    // Switches.
    changes['challenge_100k_euros_enabled'] = _eurosOn ? 'true' : 'false';
    changes['referral_enabled'] = _refOn ? 'true' : 'false';
    try {
      await _service.adminSystemConfigUpdate(changes);
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('cfg_saved'))));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${l.t('error')}: ${e.toString().replaceFirst('Exception: ', '')}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('${l.t('error')}: $_error'));
    final creditEur = ((int.tryParse(_g('challenge_seat_credit_cents', '250')) ?? 250) / 100)
        .toStringAsFixed(2);
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
          children: [
            _challengesCard(l),
            const SizedBox(height: 16),
            _referralsCard(l, creditEur),
            const SizedBox(height: 16),
            _adminsCard(l),
          ],
        ),
        Positioned(
          left: 16, right: 16, bottom: 16,
          child: FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save),
            label: Text(l.t('cfg_save_all')),
          ),
        ),
      ],
    );
  }

  // ── RETOS ──────────────────────────────────────────────────────────────────
  Widget _challengesCard(AppLocalizations l, [String creditEur = '']) {
    creditEur = ((int.tryParse(_g('challenge_seat_credit_cents', '250')) ?? 250) / 100).toStringAsFixed(2);
    return _section(
      icon: Icons.emoji_events, color: Colors.amber.shade800,
      title: l.t('cfg_reptes'), intro: l.t('cfg_intro_reptes'),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l.t('cfg_euros_on')),
          subtitle: Text(l.t('cfg_euros_on_help'), style: _help),
          value: _eurosOn,
          onChanged: (v) => setState(() => _eurosOn = v),
        ),
        _numField('challenge_days_required', l.t('cfg_days_req'), l.t('cfg_days_req_help'), _g('challenge_days_required', '365'), suffix: l.t('ch_days_unit')),
        _numField('challenge_km_target', l.t('cfg_km_target'), l.t('cfg_km_target_help'), _g('challenge_km_target', '100000'), suffix: 'km'),
        _numField('challenge_seat_credit_cents', l.t('cfg_credit_eur'), l.t('cfg_credit_eur_help'), creditEur, suffix: '€'),
        const Divider(height: 24),
        Text(l.t('cfg_antifraud'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        Text(l.t('cfg_antifraud_help'), style: _help),
        const SizedBox(height: 8),
        _numField('challenge_max_jump', l.t('cfg_max_jump'), '', _g('challenge_max_jump', '2000'), suffix: 'km'),
        _numField('challenge_max_income', l.t('cfg_max_income'), '', _g('challenge_max_income', '1500'), suffix: '€'),
      ],
    );
  }

  // ── REFERIDOS ──────────────────────────────────────────────────────────────
  Widget _referralsCard(AppLocalizations l, String creditEur) {
    return _section(
      icon: Icons.card_giftcard, color: Colors.green.shade700,
      title: l.t('cfg_referits'), intro: l.t('cfg_intro_referits'),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l.t('cfg_ref_on')),
          value: _refOn,
          onChanged: (v) => setState(() => _refOn = v),
        ),
        const SizedBox(height: 8),
        Text(l.t('cfg_ref_milestones'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        Text(l.t('cfg_ref_milestones_help'), style: _help),
        const SizedBox(height: 8),
        for (var n = 1; n <= 5; n++) _milestoneRow(l, n),
        const Divider(height: 24),
        _numField('referral_validation_days', l.t('cfg_ref_validation'), l.t('cfg_ref_validation_help'), _g('referral_validation_days', '30'), suffix: l.t('ch_days_unit')),
        _numField('referral_annual_max_days', l.t('cfg_ref_annual_max'), l.t('cfg_ref_annual_max_help'), _g('referral_annual_max_days', '360'), suffix: l.t('ch_days_unit')),
        const Divider(height: 24),
        Text(l.t('cfg_antifraud'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 8),
        _numField('referral_max_shares_per_day', l.t('cfg_ref_shares_day'), '', _g('referral_max_shares_per_day', '20')),
        _numField('referral_max_per_ip_24h', l.t('cfg_ref_ip_24h'), '', _g('referral_max_per_ip_24h', '3')),
        _numField('referral_cancellation_grace_days', l.t('cfg_ref_grace'), '', _g('referral_cancellation_grace_days', '15'), suffix: l.t('ch_days_unit')),
      ],
    );
  }

  // ── ADMINISTRADORES (Fase 4: antes vivía en el AppBar del panel) ──────────
  Widget _adminsCard(AppLocalizations l) {
    return _section(
      icon: Icons.shield, color: Colors.deepPurple,
      title: l.t('admin_manage_title'), intro: l.t('admin_current'),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.admin_panel_settings, size: 18),
            label: Text(l.t('admin_manage_title')),
            onPressed: _manageAdminsDialog,
          ),
        ),
      ],
    );
  }

  // Gestión de administradores: lista los actuales (quitar) y permite añadir.
  Future<void> _manageAdminsDialog() async {
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

  // Un nivel de referidos: "al llegar a X invitados válidos → Y días gratis".
  Widget _milestoneRow(AppLocalizations l, int n) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 54, child: Text(l.t('cfg_ref_level', {'n': '$n'}), style: const TextStyle(fontWeight: FontWeight.w600))),
          Expanded(
            child: _plainNumField('referral_milestone_${n}_required',
                _g('referral_milestone_${n}_required', ''), l.t('cfg_ref_required')),
          ),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.arrow_forward, size: 16, color: Colors.grey)),
          Expanded(
            child: _plainNumField('referral_milestone_${n}_days',
                _g('referral_milestone_${n}_days', ''), l.t('cfg_ref_days')),
          ),
        ],
      ),
    );
  }

  // ── Helpers de UI ───────────────────────────────────────────────────────────
  static const _help = TextStyle(fontSize: 11, color: Colors.grey);

  Widget _section({required IconData icon, required Color color, required String title,
      required String intro, required List<Widget> children}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, color: color),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 4),
            Text(intro, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _numField(String key, String label, String help, String value, {String? suffix}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: _c(key, value),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          helperText: help.isEmpty ? null : help,
          helperMaxLines: 2,
          suffixText: suffix,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _plainNumField(String key, String value, String hint) {
    return TextField(
      controller: _c(key, value),
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        isDense: true, hintText: hint, border: const OutlineInputBorder(),
      ),
    );
  }
}
