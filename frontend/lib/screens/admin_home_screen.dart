import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';
import '../services/data_service.dart';
import '../services/push_service.dart';
import 'admin_billing_screen.dart';
import 'admin_companies_screen.dart';
import 'admin_screen.dart';
import 'admin_theme.dart';

/// Portada del panel de administración (rediseño "eléctrico", Fase 1).
/// Combina: centro de control (anillo de salud + KPIs + semáforos de crons),
/// bandeja de trabajo (pendientes de todos los módulos con acción directa) y
/// módulos en tarjetas (abren las pestañas del AdminScreen existente).
/// Tema oscuro propio: entrar aquí se siente como "la sala de máquinas".
class AdminHomeScreen extends StatefulWidget {
  const AdminHomeScreen({super.key});

  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends State<AdminHomeScreen> {
  final _service = DataService();
  late Future<Map<String, dynamic>> _future = _service.adminOverview();
  late Future<Map<String, dynamic>> _dailyFuture = _service.adminDailyMetrics();

  @override
  void initState() {
    super.initState();
    // Registrar el token push del admin (recibe tickets de soporte y avisos de
    // límite). El admin NO tiene empresa -> tenant vacío. Sin esto, al iniciar
    // sesión como admin el token del dispositivo seguía asignado al usuario
    // anterior y el admin se quedaba sin token (no le llegaba nada).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) PushService.instance.ensureRegistered(context, '');
    });
  }

  void _reload() => setState(() {
        _future = _service.adminOverview();
        _dailyFuture = _service.adminDailyMetrics();
      });

  // Abre un módulo: -2 = Empresas y -3 = Facturación; 0..5 = pantalla propia
  // del módulo (AdminModuleScreen, sin pestañas). Recarga al volver.
  Future<void> _openTab(int tab) async {
    final Widget page = switch (tab) {
      -2 => const AdminCompaniesScreen(),
      -3 => const AdminBillingScreen(),
      _ => AdminModuleScreen(module: tab),
    };
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    _reload();
  }

  // Reorganización del dashboard: "Seguridad" se dividió en Monitorización
  // (métricas+semáforos+flags) y Auditoría; el fraude vive ahora en Referidos.
  // 0 Soporte · 1 Retos · 2 Referidos · 3 Monitorización · 4 Config · 5 Auditoría.
  static const _moduleTab = {
    'company': -2, 'incidents': 0, 'challenges': 1, 'referrals': 2,
    'monitoring': 3, 'config': 4, 'audit': 5,
  };

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    // Tema oscuro local: solo el panel de admin vive en modo "sala de máquinas".
    return Theme(
      data: adminDarkTheme(),
      child: Scaffold(
        backgroundColor: AdminColors.bg,
        appBar: AppBar(
          backgroundColor: AdminColors.bg,
          foregroundColor: AdminColors.text,
          elevation: 0,
          title: Row(
            children: [
              Container(
                width: 30, height: 30,
                decoration: BoxDecoration(
                  color: AdminColors.amberBg, borderRadius: BorderRadius.circular(9)),
                child: const Icon(Icons.shield, size: 17, color: AdminColors.amber),
              ),
              const SizedBox(width: 10),
              Text(l.t('admin_title'),
                  style: const TextStyle(fontSize: 16, color: AdminColors.text)),
            ],
          ),
          actions: [
            IconButton(
              tooltip: l.t('logout'),
              icon: const Icon(Icons.logout, size: 20, color: AdminColors.secondary),
              onPressed: () => Supabase.instance.client.auth.signOut(),
            ),
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${snap.error}',
                        style: const TextStyle(color: AdminColors.red, fontSize: 13),
                        textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    OutlinedButton(
                        onPressed: _reload, child: Text(l.t('retry'))),
                  ],
                ),
              );
            }
            final d = snap.data ?? {};
            return adminConstrained(RefreshIndicator(
              color: AdminColors.teal,
              backgroundColor: AdminColors.card,
              onRefresh: () async => _reload(),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: [
                  _statusRow(l, d),
                  const SizedBox(height: 14),
                  _controlCenter(l, d),
                  const SizedBox(height: 18),
                  _dailyPulse(l, d),
                  const SizedBox(height: 18),
                  _inboxHeader(l, d),
                  const SizedBox(height: 8),
                  _inbox(l, d),
                  const SizedBox(height: 18),
                  Text(l.t('adm_home_modules'),
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w600,
                          letterSpacing: 1.5, color: AdminColors.text)),
                  const SizedBox(height: 8),
                  _modulesGrid(l, d),
                ],
              ),
            ));
          },
        ),
      ),
    );
  }

  // --- Pols diari: métricas agregadas del día. PROTECCIÓN DE DATOS: solo
  // recuentos y, en €, únicamente NUESTROS ingresos (suscripciones), nunca el
  // dinero de las carreras de los clientes.
  String _eurStr(dynamic v) => '${((v as num?)?.toDouble() ?? 0).toStringAsFixed(2).replaceAll('.', ',')} €';
  String _numStr(dynamic v) => '${(v as num?)?.toInt() ?? 0}';

  Widget _subLabel(String t) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 6),
        child: Text(t.toUpperCase(),
            style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700,
                letterSpacing: 1.3, color: AdminColors.secondary)),
      );

  // Panel ÚNICO de métricas: fila GLOBAL (totales, del overview `d`) + fila HOY
  // (del endpoint diario, async). PROTECCIÓN DE DATOS: solo recuentos y, en €,
  // únicamente NUESTROS ingresos; nunca el dinero de las carreras de los clientes.
  Widget _dailyPulse(AppLocalizations l, Map<String, dynamic> d) {
    final k = (d['kpis'] as Map?) ?? const {};
    final driversActive = (k['drivers_active'] as num?)?.toInt() ?? 0;
    final driversTotal = (k['drivers_total'] as num?)?.toInt() ?? 0;

    // Totales de plataforma (recuentos). El dinero (MRR/facturado/cupones) vive
    // en el módulo Facturación, no aquí.
    final globalTiles = <Widget>[
      _mTile(l.t('adm_kpi_companies'), _numStr(k['tenants']), AdminColors.purple),
      _mTile(l.t('adm_kpi_drivers'), '$driversActive/$driversTotal', AdminColors.blue),
      _mTile(l.t('adm_kpi_trials'), _numStr(k['trialing']), AdminColors.amber),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.t('adm_dm_title'),
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                letterSpacing: 1.5, color: AdminColors.text)),
        _subLabel(l.t('adm_dm_global')),
        Wrap(spacing: 8, runSpacing: 8, children: globalTiles),
        _subLabel(l.t('adm_dm_today')),
        FutureBuilder<Map<String, dynamic>>(
          future: _dailyFuture,
          builder: (ctx, snap) {
            if (snap.hasError) {
              return Text(l.t('adm_dm_err'),
                  style: const TextStyle(fontSize: 11, color: AdminColors.muted));
            }
            if (!snap.hasData) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AdminColors.teal)),
              );
            }
            final m = snap.data!;
            final biz = (m['business'] as Map?) ?? const {};
            final us = (m['usage'] as Map?) ?? const {};
            final gr = (m['growth'] as Map?) ?? const {};
            final pr = (m['product'] as Map?) ?? const {};
            final rate = pr['activation_rate'];
            final refunds = (biz['refunds_today'] as num?)?.toDouble() ?? 0;
            final tiles = <Widget>[
              _mTile(l.t('adm_dm_rev_today'), _eurStr(biz['revenue_today']), AdminColors.teal),
              _mTile(l.t('adm_dm_rides'), _numStr(us['rides_today']), AdminColors.amber),
              _mTile(l.t('adm_dm_dau'), _numStr(us['dau']), AdminColors.blue),
              _mTile(l.t('adm_dm_voice'), _numStr(us['transcriptions_today']), AdminColors.purple),
              _mTile(l.t('adm_dm_new_co'), _numStr(gr['new_companies_today']), AdminColors.teal),
              _mTile(l.t('adm_dm_new_dr'), _numStr(gr['new_drivers_today']), AdminColors.blue),
              _mTile(l.t('adm_dm_trials_end'), _numStr(gr['trials_ending']), AdminColors.amber),
              _mTile(l.t('adm_dm_activation'), rate == null ? '—' : '$rate%', AdminColors.teal),
              _mTile(l.t('adm_dm_at_risk'), _numStr(pr['at_risk']), AdminColors.red),
              if (refunds > 0) _mTile(l.t('adm_dm_refunds'), _eurStr(biz['refunds_today']), AdminColors.red),
            ];
            return Wrap(spacing: 8, runSpacing: 8, children: tiles);
          },
        ),
      ],
    );
  }

  Widget _mTile(String label, String value, Color color) => Container(
        width: 112,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: AdminColors.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: .28)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: color)),
            const SizedBox(height: 2),
            Text(label,
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 9.5, color: AdminColors.secondary, height: 1.15)),
          ],
        ),
      );

  // --- Semáforos: API (si hay datos, está viva) + crons + servicios externos. ---
  Widget _statusRow(AppLocalizations l, Map<String, dynamic> d) {
    final crons = (d['crons'] as Map?) ?? const {};
    bool fresh(String k) {
      final v = crons[k] as String?;
      if (v == null) return false;
      final t = DateTime.tryParse(v);
      return t != null && DateTime.now().difference(t).inHours < 48;
    }

    // Servicios externos (whisper/openai): verde salvo que la ÚLTIMA llamada
    // fallara. La inactividad NO da rojo (a diferencia de los crons).
    final services = (d['services'] as Map?) ?? const {};
    bool svcOk(String k) {
      final s = services[k];
      return !(s is Map && s['ok'] == false);
    }

    // BD (Supabase): rojo solo si la sonda falló; "slow" sigue en verde aquí
    // (el detalle de latencia se ve en el log de Auditoría).
    final db = (d['database'] as Map?) ?? const {};
    final dbOk = (db['status'] ?? 'ok') != 'error';

    // Bandeja de webhooks de Stripe: 0 eventos sin aplicar = verde.
    final webhookOk = ((d['webhook_errors'] as num?)?.toInt() ?? 0) == 0;

    // Cada semáforo es una "píldora" con punto + etiqueta, para que a igual
    // tamaño se lean como una fila ordenada aunque sean muchos.
    Widget dot(String label, bool ok) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: AdminColors.card,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                  width: 7, height: 7,
                  decoration: BoxDecoration(
                      color: ok ? AdminColors.teal : AdminColors.red,
                      shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(label,
                  style: const TextStyle(
                      fontSize: 10, letterSpacing: .8, color: AdminColors.secondary)),
            ],
          ),
        );

    // Semáforos en una fila que se reparte (salto de línea limpio si no caben).
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        dot('API', true),
            dot(l.t('adm_home_db').toUpperCase(), dbOk),
            dot(l.t('adm_home_crons').toUpperCase(),
                fresh('challenge_credits') && fresh('referral_validations')),
            dot(l.t('adm_home_backup').toUpperCase(), fresh('backup')),
            dot('STRIPE', svcOk('stripe')),
            dot('WEBHOOKS', webhookOk),
            dot('WHISPER', svcOk('whisper')),
            dot('OPENAI', svcOk('openai')),
            dot('PUSH', svcOk('push')),
      ],
    );
  }

  // --- Anillo de salud CENTRADO + estado en una línea. Las métricas viven en
  // el bloque de Resumen; el nº de la bandeja tiene su propia sección. ---
  Widget _controlCenter(AppLocalizations l, Map<String, dynamic> d) {
    final health = (d['health'] as num?)?.toInt() ?? 100;
    final ok = health >= 90;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 112, height: 112,
            child: CustomPaint(
              painter: _RingPainter(health / 100),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$health',
                        style: const TextStyle(
                            fontSize: 28, fontWeight: FontWeight.w600, color: AdminColors.text)),
                    Text(l.t('adm_home_health').toUpperCase(),
                        style: const TextStyle(
                            fontSize: 8, letterSpacing: 1.5, color: AdminColors.secondary)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(ok ? l.t('adm_home_ok') : l.t('adm_home_attention'),
              style: TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w500,
                  color: ok ? AdminColors.teal : AdminColors.amber)),
        ],
      ),
    );
  }


  // --- Bandeja de trabajo. ---
  Widget _inboxHeader(AppLocalizations l, Map<String, dynamic> d) {
    final n = ((d['inbox'] as List?) ?? const []).length;
    return Row(
      children: [
        Text(l.t('adm_home_inbox').toUpperCase(),
            style: const TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600,
                letterSpacing: 1.5, color: AdminColors.text)),
        const SizedBox(width: 8),
        if (n > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(
                color: AdminColors.redSolid,
                borderRadius: BorderRadius.circular(9)),
            child: Text('$n',
                style: const TextStyle(
                    fontSize: 10, fontWeight: FontWeight.w600,
                    color: Colors.white)),
          ),
      ],
    );
  }

  Widget _inbox(AppLocalizations l, Map<String, dynamic> d) {
    final items = ((d['inbox'] as List?) ?? const []).cast<Map>();
    if (items.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
            color: AdminColors.card, borderRadius: BorderRadius.circular(12)),
        child: Row(
          children: [
            const Icon(Icons.check_circle, size: 18, color: AdminColors.teal),
            const SizedBox(width: 10),
            Text(l.t('adm_home_inbox_empty'),
                style: const TextStyle(fontSize: 13, color: AdminColors.secondary)),
          ],
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
          color: AdminColors.card, borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: AdminColors.hairline),
            _inboxRow(l, items[i].cast<String, dynamic>()),
          ],
        ],
      ),
    );
  }

  // Colores/etiqueta/acción según el tipo de elemento.
  ({Color fg, Color bg, String tagKey, String actKey}) _typeStyle(String type) {
    switch (type) {
      case 'fraud':
        return (fg: AdminColors.red, bg: AdminColors.redBg, tagKey: 'adm_tag_fraud', actKey: 'adm_act_review');
      case 'challenge':
        return (fg: AdminColors.purple, bg: AdminColors.purpleBg, tagKey: 'adm_tag_challenge', actKey: 'adm_act_review');
      case 'ticket':
        return (fg: AdminColors.blue, bg: AdminColors.blueBg, tagKey: 'adm_tag_ticket', actKey: 'adm_act_reply');
      case 'trial':
        return (fg: AdminColors.amber, bg: AdminColors.amberBg, tagKey: 'adm_tag_trial', actKey: 'adm_act_view');
      default:
        return (fg: AdminColors.coral, bg: AdminColors.coralBg, tagKey: 'adm_tag_error', actKey: 'adm_act_view');
    }
  }

  Widget _inboxRow(AppLocalizations l, Map<String, dynamic> it) {
    final type = (it['type'] as String?) ?? 'error';
    final s = _typeStyle(type);
    final tab = _moduleTab[it['module']] ?? 0;
    return InkWell(
      onTap: () => _openTab(tab),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: s.bg, borderRadius: BorderRadius.circular(6)),
              child: Text(l.t(s.tagKey),
                  style: TextStyle(
                      fontSize: 9, fontWeight: FontWeight.w600,
                      letterSpacing: 1, color: s.fg)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text((it['title'] as String?) ?? '—',
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: AdminColors.text)),
                  if ((it['subtitle'] as String?)?.isNotEmpty == true)
                    Text(it['subtitle'] as String,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(fontSize: 10, color: AdminColors.muted)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                border: Border.all(color: s.fg.withValues(alpha: .55)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(l.t(s.actKey),
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w500, color: s.fg)),
            ),
          ],
        ),
      ),
    );
  }

  // --- Módulos en tarjetas. ---
  Widget _modulesGrid(AppLocalizations l, Map<String, dynamic> d) {
    final p = (d['pending'] as Map?) ?? const {};
    final k = (d['kpis'] as Map?) ?? const {};
    int pi(String key) => (p[key] as num?)?.toInt() ?? 0;

    final modules = <_Module>[
      _Module(l.t('admin_companies'), Icons.business, AdminColors.purple,
          '${k['tenants'] ?? 0} · ${l.t('adm_kpi_trials').toLowerCase()}: ${k['trialing'] ?? 0}',
          0, -2),
      _Module(l.t('adm_mod_support'), Icons.forum, AdminColors.blue,
          l.t('adm_pending_n', {'n': '${pi('tickets')}'}), pi('tickets'), 0),
      _Module(l.t('admin_challenges'), Icons.emoji_events, AdminColors.amber,
          l.t('adm_pending_n', {'n': '${pi('challenges')}'}), pi('challenges'), 1),
      // Referidos incluye ahora el submenú de Fraude (badge = alertas de fraude).
      _Module(l.t('adm_ref_tab'), Icons.card_giftcard, AdminColors.pink,
          l.t('adm_pending_n', {'n': '${pi('fraud')}'}), pi('fraud'), 2),
      _Module(l.t('adm_mon_tab'), Icons.monitor_heart, AdminColors.teal, '', 0, 3),
      _Module(l.t('adm_audit_tab'), Icons.receipt_long, AdminColors.gray, '', 0, 5),
      _Module(l.t('adm_mod_billing'), Icons.payments, AdminColors.teal,
          '${(k['mrr_estimate'] as num?)?.toStringAsFixed(0) ?? '0'}€/mes',
          (k['past_due'] as num?)?.toInt() ?? 0, -3),
      _Module(l.t('adm_cfg_tab'), Icons.settings, AdminColors.gray, '', 0, 4),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 170, mainAxisExtent: 92,
        crossAxisSpacing: 8, mainAxisSpacing: 8,
      ),
      itemCount: modules.length,
      itemBuilder: (context, i) {
        final m = modules[i];
        final enabled = m.tab != -1; // -1 = módulo aún no disponible
        return InkWell(
          onTap: enabled ? () => _openTab(m.tab) : null,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AdminColors.card,
              border: Border.all(color: m.color.withValues(alpha: .25)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(m.icon, size: 20,
                        color: enabled ? m.color : m.color.withValues(alpha: .4)),
                    const Spacer(),
                    Text(m.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w500,
                            color: enabled ? AdminColors.text : AdminColors.muted)),
                    if (m.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(m.subtitle,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 10, color: AdminColors.muted)),
                    ],
                  ],
                ),
                if (m.badge > 0)
                  Positioned(
                    top: 0, right: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                          color: m.color.withValues(alpha: .9),
                          borderRadius: BorderRadius.circular(8)),
                      child: Text('${m.badge}',
                          style: const TextStyle(
                              fontSize: 9, fontWeight: FontWeight.w600,
                              color: AdminColors.bg)),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Module {
  final String title;
  final IconData icon;
  final Color color;
  final String subtitle;
  final int badge;
  final int tab; // pestaña del AdminScreen; -1 = deshabilitado (próxima fase)
  const _Module(this.title, this.icon, this.color, this.subtitle, this.badge, this.tab);
}

/// Anillo de salud: pista gris + arco de progreso con extremos redondeados.
class _RingPainter extends CustomPainter {
  final double fraction; // 0..1
  _RingPainter(this.fraction);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 6;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..color = AdminColors.hairline;
    canvas.drawCircle(center, radius, track);

    final color = fraction >= .8
        ? AdminColors.teal
        : (fraction >= .5 ? AdminColors.amber : AdminColors.red);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2, 2 * math.pi * fraction.clamp(0, 1), false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fraction != fraction;
}
