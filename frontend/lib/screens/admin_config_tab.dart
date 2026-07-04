import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import 'admin_theme.dart';

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
  bool _kmOn = true;
  bool _daysOn = true;
  bool _maintenanceOn = false;

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
        _kmOn = _g('challenge_km_enabled', 'true') != 'false';
        _daysOn = _g('challenge_days_enabled', 'true') != 'false';
        _maintenanceOn = _g('maintenance_mode', 'false') == 'true';
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
    _ctrls.forEach((key, ctrl) => changes[key] = ctrl.text.trim());
    // Switches.
    changes['challenge_100k_euros_enabled'] = _eurosOn ? 'true' : 'false';
    changes['referral_enabled'] = _refOn ? 'true' : 'false';
    changes['challenge_km_enabled'] = _kmOn ? 'true' : 'false';
    changes['challenge_days_enabled'] = _daysOn ? 'true' : 'false';
    changes['maintenance_mode'] = _maintenanceOn ? 'true' : 'false';
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
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
          children: [
            _challengesCard(l),
            const SizedBox(height: 16),
            _referralsCard(l),
            const SizedBox(height: 16),
            _generalCard(l),
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
  Widget _challengesCard(AppLocalizations l) {
    final mult = int.tryParse(_g('challenge_level_multiplier', '2')) ?? 2;
    final cycle = int.tryParse(_g('challenge_level_cycle', '4')) ?? 4;
    return _section(
      icon: Icons.emoji_events, color: AdminColors.amber,
      title: l.t('cfg_reptes'), intro: l.t('cfg_intro_reptes'),
      children: [
        // Los 3 retos, cada uno con activar/desactivar, objetivo base y preview.
        _challengeBlock(l, l.t('cfg_ch_km'), Icons.speed, _kmOn,
            (v) => setState(() => _kmOn = v),
            'challenge_km_target', _g('challenge_km_target', '100000'), 'km', mult, cycle),
        const Divider(height: 20),
        _challengeBlock(l, l.t('cfg_ch_days'), Icons.calendar_today, _daysOn,
            (v) => setState(() => _daysOn = v),
            'challenge_days_required', _g('challenge_days_required', '365'),
            l.t('ch_days_unit'), 1, 1), // días no escalan por ciclo (target fijo)
        const Divider(height: 20),
        _challengeBlock(l, l.t('cfg_ch_money'), Icons.euro, _eurosOn,
            (v) => setState(() => _eurosOn = v),
            'challenge_money_target', _g('challenge_money_target', '100000'), '€', mult, cycle),
        const Divider(height: 24),
        // Fórmula de niveles (aplica a km e ingresos).
        Text(l.t('cfg_ch_formula'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        Text(l.t('cfg_ch_formula_help'), style: _help),
        const SizedBox(height: 4),
        _numField('challenge_level_multiplier', l.t('cfg_ch_mult'), '', '$mult', suffix: '×'),
        _numField('challenge_level_cycle', l.t('cfg_ch_cycle'), '', '$cycle'),
        Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            border: Border.all(color: AdminColors.teal.withValues(alpha: .28)),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(children: [
            const Icon(Icons.auto_awesome, size: 15, color: AdminColors.teal),
            const SizedBox(width: 8),
            Expanded(child: Text(l.t('cfg_credit_auto'),
                style: const TextStyle(fontSize: 11, color: AdminColors.secondary))),
          ]),
        ),
        const Divider(height: 24),
        Text(l.t('cfg_antifraud'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        Text(l.t('cfg_antifraud_help'), style: _help),
        const SizedBox(height: 8),
        _numField('challenge_max_jump', l.t('cfg_max_jump'), '', _g('challenge_max_jump', '2000'), suffix: 'km'),
        _numField('challenge_max_income', l.t('cfg_max_income'), '', _g('challenge_max_income', '1500'), suffix: '€'),
      ],
    );
  }

  // Un reto: cabecera con switch + objetivo base + preview de los primeros
  // niveles (calculados con la misma fórmula del backend).
  Widget _challengeBlock(AppLocalizations l, String title, IconData icon,
      bool enabled, ValueChanged<bool> onToggle, String key, String value,
      String suffix, int mult, int cycle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(icon, size: 16, color: enabled ? AdminColors.amber : AdminColors.muted),
          const SizedBox(width: 8),
          Expanded(child: Text(title,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600,
                  color: enabled ? AdminColors.text : AdminColors.muted))),
          Switch(value: enabled, onChanged: onToggle),
        ]),
        if (enabled) ...[
          _numField(key, l.t('cfg_ch_base'), '', value, suffix: suffix, livePreview: true),
          Builder(builder: (ctx) {
            // Preview reactivo: usa el valor del controlador.
            final base = double.tryParse(
                    (_ctrls[key]?.text ?? value).replaceAll(',', '.')) ??
                0;
            final levels = [
              for (var lvl = 1; lvl <= 6; lvl++)
                ((lvl - 1) % (cycle < 1 ? 1 : cycle) == 0 ? base : base * mult),
            ];
            return Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 2),
              child: Wrap(
                spacing: 6, runSpacing: 4,
                children: [
                  for (var i = 0; i < levels.length; i++)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: AdminColors.amberBg,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'N${i + 1}: ${levels[i].toStringAsFixed(0)}$suffix',
                        style: const TextStyle(fontSize: 10, color: AdminColors.amber),
                      ),
                    ),
                ],
              ),
            );
          }),
        ],
      ],
    );
  }

  // ── GENERAL ─────────────────────────────────────────────────────────────────
  Widget _generalCard(AppLocalizations l) {
    return _section(
      icon: Icons.tune, color: AdminColors.blue,
      title: l.t('cfg_general'), intro: l.t('cfg_general_intro'),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l.t('cfg_maintenance')),
          subtitle: Text(l.t('cfg_maintenance_help'), style: _help),
          value: _maintenanceOn,
          onChanged: (v) => setState(() => _maintenanceOn = v),
        ),
        if (_maintenanceOn)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextField(
              controller: _c('maintenance_message', _g('maintenance_message', '')),
              maxLines: 2,
              style: const TextStyle(fontSize: 13, color: AdminColors.text),
              decoration: InputDecoration(
                labelText: l.t('cfg_maintenance_msg'),
                hintText: l.t('cfg_maintenance_msg_hint'),
              ),
            ),
          ),
      ],
    );
  }

  // ── REFERIDOS ──────────────────────────────────────────────────────────────
  Widget _referralsCard(AppLocalizations l) {
    return _section(
      icon: Icons.card_giftcard, color: AdminColors.pink,
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
        // Ventana de validación: días desde el PRIMER PAGO del invitado; si
        // sigue de alta al vencer, se conceden los días por hitos al referidor.
        _numField('referral_pay_window_days', l.t('cfg_ref_pay_window'), l.t('cfg_ref_pay_window_help'), _g('referral_pay_window_days', '15'), suffix: l.t('ch_days_unit')),
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
      icon: Icons.shield, color: AdminColors.purple,
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
    await showAdminDialog<void>(
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
                                  leading: const Icon(Icons.shield, color: AdminColors.purple),
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
  static const _help = TextStyle(fontSize: 11, color: AdminColors.muted);

  Widget _section({required IconData icon, required Color color, required String title,
      required String intro, required List<Widget> children}) {
    return Container(
      decoration: adminCardBox(borderColor: color),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, color: color),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 4),
            Text(intro, style: const TextStyle(fontSize: 12, color: AdminColors.muted)),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  // Fila de ajuste estilo panel: etiqueta y ayuda a la izquierda, campo
  // numérico compacto a la derecha (como los settings modernos).
  Widget _numField(String key, String label, String help, String value, {String? suffix, bool livePreview = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 13, color: AdminColors.text)),
                if (help.isNotEmpty)
                  Text(help,
                      style: const TextStyle(
                          fontSize: 10.5, color: AdminColors.muted)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 110,
            child: TextField(
              controller: _c(key, value),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 13, color: AdminColors.text),
              onChanged: livePreview ? (_) => setState(() {}) : null,
              decoration: InputDecoration(
                isDense: true,
                suffixText: suffix,
                suffixStyle: const TextStyle(
                    fontSize: 11, color: AdminColors.muted),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 9),
              ),
            ),
          ),
        ],
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
