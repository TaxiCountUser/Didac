import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Paleta "eléctrica" del panel de administración (rediseño 2026-07).
/// Tema oscuro propio, independiente del tema ámbar de la app:
/// verde = dinero · violeta = empresas · azul = soporte/personas ·
/// ámbar = pruebas/retos · rojo = fraude/peligro · coral = errores ·
/// rosa = referidos · gris = configuración.
class AdminColors {
  static const bg = Color(0xFF0B0B0F);
  static const card = Color(0xFF12121A);
  static const hairline = Color(0xFF1D1D26);
  static const text = Color(0xFFF1EFE8);
  static const secondary = Color(0xFF7D8A94);
  static const muted = Color(0xFF66616E);
  static const teal = Color(0xFF5DCAA5);
  static const purple = Color(0xFFAFA9EC);
  static const blue = Color(0xFF85B7EB);
  static const amber = Color(0xFFFAC775);
  static const red = Color(0xFFF09595);
  static const redSolid = Color(0xFFE24B4A);
  static const coral = Color(0xFFF0997B);
  static const pink = Color(0xFFED93B1);
  static const gray = Color(0xFFB4B2A9);
  // Fondos oscuros de las etiquetas por tipo.
  static const redBg = Color(0xFF38161C);
  static const blueBg = Color(0xFF16273C);
  static const amberBg = Color(0xFF33241A);
  static const purpleBg = Color(0xFF2C1A38);
  static const tealBg = Color(0xFF16323C);
  static const coralBg = Color(0xFF331D15);
}

/// Tema oscuro local del panel: se aplica con un `Theme(...)` alrededor del
/// Scaffold para que los diálogos y controles estándar salgan oscuros también.
ThemeData adminDarkTheme() => ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AdminColors.bg,
      colorScheme: const ColorScheme.dark(
        primary: AdminColors.teal,
        surface: AdminColors.card,
        onSurface: AdminColors.text,
        error: AdminColors.redSolid,
      ),
      dialogTheme: const DialogThemeData(backgroundColor: AdminColors.card),
      useMaterial3: true,
    );

/// Chip de estado de suscripción con el color del rediseño.
class AdminStatusChip extends StatelessWidget {
  final String? status;
  final int trialDaysLeft;
  const AdminStatusChip({super.key, required this.status, this.trialDaysLeft = 0});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final (label, fg, bg) = switch (status) {
      'active' => (l.t('st_active'), AdminColors.teal, AdminColors.tealBg),
      'trialing' => (
          trialDaysLeft > 0
              ? l.t('adm_trial_days', {'n': '$trialDaysLeft'})
              : l.t('st_trial'),
          AdminColors.amber,
          AdminColors.amberBg
        ),
      'past_due' => (l.t('st_past_due'), AdminColors.red, AdminColors.redBg),
      'canceled' => (l.t('st_canceled'), AdminColors.muted, AdminColors.hairline),
      _ => (l.t('st_inactive'), AdminColors.muted, AdminColors.hairline),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(9)),
      child: Text(label,
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w500, color: fg)),
    );
  }
}

/// Avatar cuadrado con las iniciales de la empresa.
class AdminInitialsAvatar extends StatelessWidget {
  final String name;
  final Color color;
  final Color bg;
  final double size;
  const AdminInitialsAvatar(
      {super.key, required this.name, this.color = AdminColors.purple,
      this.bg = AdminColors.purpleBg, this.size = 32});

  @override
  Widget build(BuildContext context) {
    final parts = name.trim().split(RegExp(r'\s+'));
    final initials = parts.length >= 2
        ? '${parts[0][0]}${parts[1][0]}'
        : (name.trim().isEmpty ? '?' : name.trim().substring(0, name.trim().length >= 2 ? 2 : 1));
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(size * .28)),
      alignment: Alignment.center,
      child: Text(initials.toUpperCase(),
          style: TextStyle(
              fontSize: size * .36, fontWeight: FontWeight.w600, color: color)),
    );
  }
}
