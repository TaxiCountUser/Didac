import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../l10n/app_localizations.dart';
import '../models/profile.dart';
import '../services/data_service.dart';
import 'referral_screen.dart';

/// Clave i18n del estado de suscripción.
String subscriptionStatusKey(String? status) => switch (status) {
      'active' => 'st_active',
      'trialing' => 'st_trial',
      'past_due' => 'st_past_due',
      'canceled' => 'st_canceled',
      _ => 'st_inactive',
    };

/// Etiqueta legible del estado de suscripción.
String subscriptionStatusLabel(String? status) {
  switch (status) {
    case 'active':
      return 'Activa';
    case 'trialing':
      return 'Periodo de prueba';
    case 'past_due':
      return 'Pago pendiente';
    case 'canceled':
      return 'Cancelada';
    default:
      return 'Inactiva';
  }
}

Color subscriptionStatusColor(String? status) {
  switch (status) {
    case 'active':
    case 'trialing':
      return const Color(0xFF2E7D32);
    case 'past_due':
      return const Color(0xFFEF6C00);
    default:
      return const Color(0xFFC62828);
  }
}

bool subscriptionIsActive(String? status) => status == 'active' || status == 'trialing';

/// Pantalla de suscripción del Owner: plan actual, elegir/cambiar plan y portal.
class SubscriptionScreen extends StatefulWidget {
  final Profile profile;
  const SubscriptionScreen({super.key, required this.profile});

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  final _service = DataService();
  Map<String, dynamic>? _billing;
  Map<String, dynamic>? _savings; // ahorro por retos/referidos (Loop #8)
  Map<String, dynamic>? _seatInfo; // periodo/precio real del asiento (para avisar del cobro)
  int? _pendingSeats; // ajuste de asientos acumulado, pendiente de aplicar
  int _activeDrivers = 1;
  bool _loading = true;
  bool _busy = false;
  bool _busySeats = false;
  bool _yearly = false; // periodo elegido para suscribirse
  String? _error;
  bool _couponShown = false; // el aviso del cupón se muestra una vez por entrada

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final b = await _service.fetchTenantBilling(widget.profile.tenantId);
      int drivers = 1;
      try {
        final list = await _service.listDrivers();
        final n = list.where((d) => d['active'] != false).length;
        drivers = n < 1 ? 1 : n; // mínimo 1 asiento (el propio autónomo)
      } catch (_) {/* best-effort */}
      // Días gratis por retos/referidos: best-effort, no bloquea la pantalla.
      try {
        final s = await _service.tenantFreeDays();
        if (mounted) setState(() => _savings = s);
      } catch (_) {/* sin tarjetas de días gratis */}
      // Periodo/precio real del asiento, para avisar del cobro al añadir. Best-effort.
      try {
        final si = await _service.fetchSeatInfo();
        if (mounted) setState(() => _seatInfo = si);
      } catch (_) {/* sin info de asiento (aún en prueba) */}
      if (!mounted) return;
      setState(() {
        _billing = b;
        _activeDrivers = drivers;
        _loading = false;
        _error = null;
      });
      // Aviso del cupón activo (con "copiar"), una sola vez por entrada.
      if (!_couponShown) {
        _couponShown = true;
        try {
          final c = await _service.tenantActiveCoupon();
          if (mounted && c['show'] == true && (c['code'] as String?)?.isNotEmpty == true) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _showCouponDialog(c['code'] as String, (c['pct'] as num?)?.toInt() ?? 0);
            });
          }
        } catch (_) {/* sin aviso de cupón */}
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// Formatea un importe en euros sin decimales innecesarios (15,6 / 100).
  String _eur(double v) {
    final s = (v == v.roundToDouble()) ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
    return '${s.replaceAll('.', ',')} €';
  }

  Future<void> _openExternal(String url) async {
    final uri = Uri.parse(url);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.t('sub_no_browser'))));
    }
  }

  Future<void> _subscribe() async {
    setState(() => _busy = true);
    try {
      final url = await _service.createCheckoutSession(seatPriceFor(_yearly));
      await _openExternal(url);
    } catch (e) {
      if (mounted) {
        // Stripe sin configurar -> mensaje claro en vez del error técnico.
        final msg = e.toString().toLowerCase().contains('configurado')
            ? context.l10n.t('sub_unavailable')
            : '${context.l10n.t('error')}: $e';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openPortal() async {
    setState(() => _busy = true);
    try {
      final url = await _service.createPortalSession();
      await _openExternal(url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Aviso del cupón activo: código grande + botón de copiar. Anual únicamente.
  Future<void> _showCouponDialog(String code, int pct) async {
    final l = context.l10n;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          const Icon(Icons.local_offer, color: Colors.green),
          const SizedBox(width: 8),
          Expanded(child: Text(l.t('sub_coupon_popup_title', {'pct': '$pct'}))),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.t('sub_coupon_popup_body'), style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: .08),
                border: Border.all(color: Colors.green.withValues(alpha: .4)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                Expanded(
                  child: SelectableText(code,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, color: Colors.green),
                  tooltip: l.t('sub_coupon_copy'),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(l.t('sub_coupon_copied'))));
                  },
                ),
              ]),
            ),
            const SizedBox(height: 8),
            Text(l.t('sub_coupon_popup_note'),
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.t('close'))),
          FilledButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: Text(l.t('sub_coupon_copy')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('${l.t('error')}: $_error'));

    final b = _billing ?? {};
    final status = b['subscription_status'] as String?;
    final hasCustomer = (b['stripe_customer_id'] as String?)?.isNotEmpty == true;
    // Días de prueba restantes (si sigue dentro del periodo de prueba).
    final trialEnds = b['trial_ends_at'] == null
        ? null
        : DateTime.tryParse(b['trial_ends_at'] as String)?.toLocal();
    final trialDaysLeft = (trialEnds != null && DateTime.now().isBefore(trialEnds))
        ? trialEnds.difference(DateTime.now()).inDays + 1
        : 0;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _currentPlanCard(l, status, hasCustomer, trialDaysLeft),
          const SizedBox(height: 12),
          _seatsCard(l, status),
          if (_savings != null) ...[
            const SizedBox(height: 12),
            _savingsCards(l),
          ],
          const SizedBox(height: 24),
          Text(
            subscriptionIsActive(status) ? l.t('sub_billing_period') : l.t('sub_choose_plan'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (subscriptionIsActive(status)) ...[
            const SizedBox(height: 4),
            Text(l.t('sub_billing_period_hint'),
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
          const SizedBox(height: 8),
          Center(
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: false, label: Text(l.t('sub_monthly'))),
                ButtonSegment(value: true, label: Text(l.t('sub_yearly'))),
              ],
              selected: {_yearly},
              onSelectionChanged: (s) => setState(() => _yearly = s.first),
            ),
          ),
          const SizedBox(height: 8),
          _seatPlanCard(l, status),
          const SizedBox(height: 12),
          Card(
            color: Colors.amber.shade50,
            child: ListTile(
              leading: const Icon(Icons.card_giftcard, color: Colors.amber),
              title: Text(l.t('set_referral')),
              subtitle: Text(l.t('set_referral_sub')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => ReferralScreen(profile: widget.profile)),
              ),
            ),
          ),
          if (widget.profile.isOwner) ...[
            const SizedBox(height: 24),
            _dangerZone(l),
          ],
          if (_busy) const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
        ],
      ),
    );
  }

  // Zona de baja: dar de baja la empresa (solo Owner). Cancela la suscripción,
  // cierra la cuenta (retención GDPR) y elimina los accesos.
  Widget _dangerZone(AppLocalizations l) {
    if (widget.profile.role != 'owner') return const SizedBox.shrink();
    return Card(
      color: const Color(0xFFFDECEA),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.warning_amber_rounded, color: Color(0xFFC62828)),
              const SizedBox(width: 8),
              Text(l.t('sub_danger_title'),
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFC62828))),
            ]),
            const SizedBox(height: 6),
            Text(l.t('sub_danger_sub'), style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFC62828),
                side: const BorderSide(color: Color(0xFFC62828)),
              ),
              onPressed: _busy ? null : _closeCompany,
              icon: const Icon(Icons.no_accounts),
              label: Text(l.t('sub_close_company')),
            ),
          ],
        ),
      ),
    );
  }

  // Cancelar / reactivar la suscripción (a fin de periodo).
  Future<void> _setCancel({required bool resume}) async {
    final l = context.l10n;
    if (!resume) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l.t('sub_cancel_title')),
          content: Text(l.t('sub_cancel_msg')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('sub_cancel_keep'))),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC62828)),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.t('sub_cancel_ok')),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy = true);
    try {
      await _service.cancelSubscription(resume: resume);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l.t(resume ? 'sub_resume_done' : 'sub_cancel_done'))));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l.t('error')}: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Baja de la empresa: exige escribir el nombre exacto y avisa de las
  // consecuencias. Al confirmar, cierra la cuenta y cierra sesión.
  Future<void> _closeCompany() async {
    final l = context.l10n;
    final name = (_billing?['name'] as String?)?.trim() ?? '';
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(l.t('sub_close_company')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.t('sub_close_warn')),
              const SizedBox(height: 12),
              Text(l.t('sub_close_type', {'name': name}),
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 6),
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: InputDecoration(labelText: l.t('sub_close_name_label'), isDense: true),
                onChanged: (_) => setLocal(() {}),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC62828)),
              onPressed: ctrl.text.trim().toLowerCase() == name.toLowerCase() && name.isNotEmpty
                  ? () => Navigator.pop(ctx, true)
                  : null,
              child: Text(l.t('sub_close_confirm')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await _service.closeCompany(ctrl.text.trim());
      // Cuenta cerrada: cerramos sesión (el listener global lleva al login).
      await Supabase.instance.client.auth.signOut();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l.t('error')}: $e')));
      }
    }
  }

  // --------------- Días gratis por retos/referidos ---------------
  Widget _savingsCards(AppLocalizations l) {
    final s = _savings!;
    final ch = (s['challenges_days'] as num?)?.toInt() ?? 0;
    final rf = (s['referrals_days'] as num?)?.toInt() ?? 0;
    return Row(
      children: [
        _savingsCard(l.t('sav_challenges'), ch,
            const Color(0xFF6A1B9A), Icons.emoji_events, const Key('sav_challenges')),
        const SizedBox(width: 8),
        _savingsCard(l.t('sav_referrals'), rf,
            const Color(0xFF00838F), Icons.group_add, const Key('sav_referrals')),
      ],
    );
  }

  Widget _savingsCard(String label, int days, Color color, IconData icon, Key key) {
    return Expanded(
      child: Card(
        key: key,
        child: InkWell(
          onTap: _openSavingsDetail,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            child: Column(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(height: 6),
                FittedBox(
                  child: Text(context.l10n.t('fd_days', {'n': '$days'}),
                      style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 16)),
                ),
                const SizedBox(height: 2),
                Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Modal con el detalle de las extensiones (días gratis) por retos y referidos.
  Future<void> _openSavingsDetail() async {
    final s = _savings;
    if (s == null) return;
    final l = context.l10n;
    final tCh = (s['challenges_days'] as num?)?.toInt() ?? 0;
    final tRf = (s['referrals_days'] as num?)?.toInt() ?? 0;
    final exts = ((s['challenge_extensions'] as List?) ?? []).cast<Map<String, dynamic>>();
    final miles = ((s['referral_milestones'] as List?) ?? []).cast<Map<String, dynamic>>();
    String fmtDate(String? iso) {
      final d = DateTime.tryParse(iso ?? '')?.toLocal();
      return d == null ? '' : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.t('sav_detail_title'), style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('${l.t('sav_total')}: ${l.t('fd_days', {'n': '${tCh + tRf}'})}',
                  style: Theme.of(ctx).textTheme.bodyMedium),
              Row(children: [
                _dot(const Color(0xFF6A1B9A)),
                Text(' ${l.t('sav_challenges')}: ${l.t('fd_days', {'n': '$tCh'})}   '),
                _dot(const Color(0xFF00838F)),
                Text(' ${l.t('sav_referrals')}: ${l.t('fd_days', {'n': '$tRf'})}'),
              ]),
              const SizedBox(height: 8),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.emoji_events, size: 15, color: Color(0xFF6A1B9A)),
                const SizedBox(width: 6),
                Expanded(child: Text(l.t('sav_challenges_desc'),
                    style: const TextStyle(fontSize: 11, color: Colors.grey))),
              ]),
              const SizedBox(height: 4),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.group_add, size: 15, color: Color(0xFF00838F)),
                const SizedBox(width: 6),
                Expanded(child: Text(l.t('sav_referrals_desc'),
                    style: const TextStyle(fontSize: 11, color: Colors.grey))),
              ]),
              const Divider(),
              if (exts.isEmpty && miles.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: Text(l.t('sav_none'), textAlign: TextAlign.center)),
                )
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final e in exts)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.emoji_events, size: 18, color: Color(0xFF6A1B9A)),
                            title: Text(l.t('sav_challenges')),
                            subtitle: Text(fmtDate(e['applied_at'] as String?)),
                            trailing: Text('+${(e['days_extended'] as num?)?.toInt() ?? 0}',
                                style: const TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        for (final m in miles)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.group_add, size: 18, color: Color(0xFF00838F)),
                            title: Text('${l.t('sav_referrals')} · ${l.t('ch_level', {'n': '${m['milestone_level']}'})}'),
                            subtitle: Text(fmtDate(m['created_at'] as String?)),
                            trailing: Text('+${(m['days_awarded'] as num?)?.toInt() ?? 0}',
                                style: const TextStyle(fontWeight: FontWeight.bold)),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dot(Color c) => Container(width: 10, height: 10,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle));

  // Asientos pagados (cupo de conductores). En pago se puede ajustar (comprar /
  // reducir); en prueba no hace falta (conductores ilimitados hasta el máximo).
  Widget _seatsCard(AppLocalizations l, String? status) {
    final paid = status == 'active' || status == 'past_due';
    // Asientos PAGADOS = cantidad real en Stripe (_seatInfo); drivers_limit de la
    // BD es solo el respaldo por si aún no cargó. Así se ven los que se pagan
    // (p. ej. 6) aunque haya menos conductores activos.
    final seats = (_seatInfo?['seats'] as num?)?.toInt()
        ?? (_billing?['drivers_limit'] as num?)?.toInt();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.t('seats_title'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (!paid || seats == null)
              Text(l.t('seats_trial_hint'))
            else ...[
              Text(l.t('seats_paid', {'n': '$seats'})),
              Text(l.t('seats_active', {'n': '$_activeDrivers'})),
              const SizedBox(height: 8),
              // El +/- ajusta un valor PENDIENTE: se puede subir/bajar varios de
              // golpe y se aplica todo junto con UN solo cobro y UNA confirmación.
              Builder(builder: (context) {
                final target = _pendingSeats ?? seats;
                final minSeats = _activeDrivers < 1 ? 1 : _activeDrivers;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        IconButton.filledTonal(
                          onPressed: (_busySeats || target <= minSeats)
                              ? null
                              : () => setState(() => _pendingSeats = target - 1),
                          icon: const Icon(Icons.remove),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text('$target', style: Theme.of(context).textTheme.titleLarge),
                        ),
                        IconButton.filledTonal(
                          onPressed: (_busySeats || target >= kMaxDrivers)
                              ? null
                              : () => setState(() => _pendingSeats = target + 1),
                          icon: const Icon(Icons.add),
                        ),
                        const Spacer(),
                        if (_busySeats)
                          const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                      ],
                    ),
                    if (target != seats) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Text(l.t('seats_pending', {'from': '$seats', 'to': '$target'}),
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                          ),
                          TextButton(
                            onPressed: _busySeats ? null : () => setState(() => _pendingSeats = null),
                            child: Text(l.t('cancel')),
                          ),
                          FilledButton(
                            onPressed: _busySeats ? null : () => _confirmSetSeats(seats, target),
                            child: Text(l.t('seats_apply')),
                          ),
                        ],
                      ),
                    ],
                  ],
                );
              }),
            ],
          ],
        ),
      ),
    );
  }

  /// Etiqueta del precio por asiento según el periodo REAL del plan (Stripe).
  /// Cae a los precios base de config si aún no tenemos la info.
  String _seatPriceLabel(AppLocalizations l) {
    final yearly = _seatInfo?['interval'] == 'year';
    final cents = (_seatInfo?['unit_amount'] as num?);
    final eur = cents != null
        ? (cents / 100)
        : (yearly ? kSeatYearly : kSeatMonthly);
    final txt = eur == eur.roundToDouble()
        ? eur.toStringAsFixed(0)
        : eur.toStringAsFixed(2).replaceAll('.', ',');
    return l.t(yearly ? 'seat_price_year' : 'seat_price_month', {'eur': txt});
  }

  /// Pide confirmación ANTES de cambiar los asientos. Subir cobra la parte
  /// proporcional ya; bajar acredita el sobrante en la próxima factura.
  Future<void> _confirmSetSeats(int from, int to) async {
    final l = context.l10n;
    final adding = to > from;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t(adding ? 'seat_add_title' : 'seat_remove_title')),
        content: Text(adding
            ? l.t('seat_add_msg', {'from': '$from', 'to': '$to', 'price': _seatPriceLabel(l)})
            : l.t('seat_remove_msg', {'from': '$from', 'to': '$to'})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.t(adding ? 'seat_buy_ok' : 'confirm')),
          ),
        ],
      ),
    );
    if (ok == true) await _setSeats(to);
  }

  Future<void> _setSeats(int seats) async {
    setState(() => _busySeats = true);
    try {
      final r = await _service.setSubscriptionSeats(seats);
      if (mounted) setState(() => _pendingSeats = null); // ajuste aplicado
      await _load();
      if (mounted) {
        final l = context.l10n;
        final amount = (r['amount'] as num?)?.toInt() ?? 0;
        final charged = r['charged'] == true;
        final msg = charged
            ? l.t('seats_charged', {
                'eur': (amount / 100).toStringAsFixed(2).replaceAll('.', ','),
              })
            : l.t('seats_updated', {'n': '$seats'});
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg), duration: const Duration(seconds: 5)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _busySeats = false);
    }
  }

  Widget _currentPlanCard(AppLocalizations l, String? status, bool hasCustomer, int trialDaysLeft) {
    // Con suscripción PAGADA se muestra lo que se paga: los ASIENTOS comprados
    // (cantidad de Stripe) y el periodo REAL, no los conductores activos ni el
    // toggle. En prueba aún no hay asientos: se estima por conductores activos.
    final isPaid = status == 'active' || status == 'past_due';
    final paidSeats = (_seatInfo?['seats'] as num?)?.toInt()
        ?? (_billing?['drivers_limit'] as num?)?.toInt();
    final yearly = isPaid ? (_seatInfo?['interval'] == 'year') : _yearly;
    final count = (isPaid && paidSeats != null && paidSeats > 0) ? paidSeats : _activeDrivers;
    final est = estimatedCost(count, yearly);
    return Card(
      key: const Key('current_plan_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.workspace_premium, color: Colors.amber),
                const SizedBox(width: 8),
                Text(l.t('sub_seat_plan_name'), style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                Chip(
                  label: Text(l.t(subscriptionStatusKey(status)),
                      style: const TextStyle(color: Colors.white, fontSize: 12)),
                  backgroundColor: subscriptionStatusColor(status),
                ),
              ],
            ),
            if (status == 'trialing' && trialDaysLeft > 0) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(Icons.hourglass_bottom, size: 18, color: Colors.orange),
                  const SizedBox(width: 6),
                  Text(l.t('trial_days_left', {'n': '$trialDaysLeft'}),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Text(l.t('sub_seat_current', {
              'n': '$count',
              'cost': _eur(est),
              'period': yearly ? l.t('sub_per_year') : l.t('sub_per_month'),
            })),
            if (!subscriptionIsActive(status)) ...[
              const SizedBox(height: 8),
              Text(l.t('sub_inactive_msg'), style: const TextStyle(color: Color(0xFFC62828))),
            ],
            if (hasCustomer) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('open_portal_button'),
                onPressed: _busy ? null : _openPortal,
                icon: const Icon(Icons.receipt_long),
                label: Text(l.t('sub_manage_billing')),
              ),
            ],
            // Aplicar un cupón a la suscripción activa (descuento en la próxima
            // renovación). Al suscribirse, el cupón se pone en el Checkout.
            if (hasCustomer && subscriptionIsActive(status))
              TextButton.icon(
                onPressed: _busy ? null : _applyCoupon,
                icon: const Icon(Icons.local_offer_outlined, size: 18),
                label: Text(l.t('sub_have_coupon')),
              ),
            // Cancelar / reactivar la suscripción (a fin de periodo).
            if (hasCustomer && subscriptionIsActive(status)) ...[
              if (_seatInfo?['cancel_at_period_end'] == true) ...[
                const SizedBox(height: 8),
                Text(
                  l.t('sub_cancel_scheduled', {'date': _fmtDate(_seatInfo?['current_period_end'])}),
                  style: const TextStyle(color: Color(0xFFC62828), fontWeight: FontWeight.w600),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : () => _setCancel(resume: true),
                  icon: const Icon(Icons.undo),
                  label: Text(l.t('sub_resume')),
                ),
              ] else
                TextButton.icon(
                  onPressed: _busy ? null : () => _setCancel(resume: false),
                  style: TextButton.styleFrom(foregroundColor: const Color(0xFFC62828)),
                  icon: const Icon(Icons.cancel_outlined),
                  label: Text(l.t('sub_cancel_sub')),
                ),
            ],
          ],
        ),
      ),
    );
  }

  // Aplicar un cupón a la suscripción activa: el descuento entra en la
  // PRÓXIMA renovación (no hace falta adelantar ningún pago).
  Future<void> _applyCoupon() async {
    final l = context.l10n;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('sub_have_coupon')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.t('sub_coupon_hint'), style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(labelText: l.t('sub_coupon_code'), isDense: true),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('sub_coupon_apply'))),
        ],
      ),
    );
    if (ok != true || ctrl.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final res = await _service.applySubscriptionCoupon(ctrl.text.trim());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l.t('sub_coupon_applied', {'pct': '${res['pct'] ?? ''}'})),
          duration: const Duration(seconds: 6),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Fecha corta dd/mm/aaaa a partir de un ISO (o '—').
  String _fmtDate(dynamic iso) {
    final d = DateTime.tryParse('${iso ?? ''}')?.toLocal();
    if (d == null) return '—';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  Future<void> _contactUs() {
    final subject = Uri.encodeComponent('TaxiCount — plan a medida (+$kMaxDrivers conductores)');
    return _openExternal('mailto:$kSupportEmail?subject=$subject');
  }

  // Tarjeta del modelo por asiento (lineal, sin tramo plano): precio por
  // conductor, cupones anuales y estimación para el nº actual de conductores.
  Widget _seatPlanCard(AppLocalizations l, String? status) {
    final isPaid = status == 'active' || status == 'past_due';
    final over = _activeDrivers > kMaxDrivers;
    final est = estimatedCost(_activeDrivers, _yearly);
    final perDriver = _yearly ? kSeatYearly : kSeatMonthly;
    final period = _yearly ? l.t('sub_per_year') : l.t('sub_per_month');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.t('sub_seat_plan_name'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            _row(Icons.person, l.t('sub_seat_per_driver', {'price': _eur(perDriver), 'period': period})),
            _row(Icons.info_outline, l.t('sub_seat_max', {'max': '$kMaxDrivers'})),
            const Divider(height: 20),
            // La estimación "para N conductores" y la nota SOLO al suscribirse
            // (previsualiza lo que pagará). Ya suscrito, el nº de asientos y su
            // coste se gestionan arriba en la tarjeta de asientos: aquí sobra.
            if (over) ...[
              Text(l.t('sub_over_max', {'n': '$_activeDrivers', 'max': '$kMaxDrivers'}),
                  style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFFC62828))),
              const SizedBox(height: 8),
            ] else if (!isPaid) ...[
              Text(l.t('sub_seat_estimate',
                  {'n': '$_activeDrivers', 'cost': _eur(est), 'period': period}),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(l.t('sub_seat_note'), style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 8),
            ],
            SizedBox(
              width: double.infinity,
              child: over
                  ? OutlinedButton.icon(
                      onPressed: _busy ? null : _contactUs,
                      icon: const Icon(Icons.mail_outline),
                      label: Text(l.t('sub_contact_us')))
                  : _subscribeButton(l, status),
            ),
          ],
        ),
      ),
    );
  }

  // Botón principal del plan. Si no hay suscripción -> "Suscribirse". Si ya está
  // activa, el selector mensual/anual es el PERIODO de facturación: si el periodo
  // elegido coincide con el actual (Stripe), no hay nada que cambiar; si difiere,
  // permite cambiar a ese periodo.
  Widget _subscribeButton(AppLocalizations l, String? status) {
    if (!subscriptionIsActive(status)) {
      return FilledButton(
        key: const Key('subscribe_button'),
        onPressed: _busy ? null : _subscribe,
        child: Text(l.t('sub_subscribe')),
      );
    }
    final interval = _seatInfo?['interval'] as String?; // 'month' | 'year' | null
    final period = _yearly ? l.t('sub_period_yearly') : l.t('sub_period_monthly');
    final sameAsCurrent = interval != null && (interval == 'year') == _yearly;
    if (sameAsCurrent) {
      return FilledButton(
        onPressed: null,
        child: Text(l.t('sub_current_period', {'period': period})),
      );
    }
    return FilledButton(
      key: const Key('subscribe_button'),
      onPressed: _busy ? null : _subscribe,
      child: Text(l.t('sub_switch_period', {'period': period})),
    );
  }

  Widget _row(IconData icon, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: Colors.blueGrey),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ]),
      );
}
