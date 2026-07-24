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
/// Scaffold para que TODO (diálogos, campos, menús, snackbars, switches…)
/// salga con la piel del rediseño, también al editar.
ThemeData adminDarkTheme() => ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AdminColors.bg,
      colorScheme: const ColorScheme.dark(
        primary: AdminColors.teal,
        secondary: AdminColors.purple,
        surface: AdminColors.card,
        onSurface: AdminColors.text,
        error: AdminColors.redSolid,
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: AdminColors.card,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: AdminColors.hairline,
        contentTextStyle: TextStyle(color: AdminColors.text, fontSize: 13),
        behavior: SnackBarBehavior.floating,
      ),
      popupMenuTheme: const PopupMenuThemeData(
        color: AdminColors.card,
        surfaceTintColor: Colors.transparent,
        textStyle: TextStyle(color: AdminColors.text, fontSize: 13),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AdminColors.card,
        labelStyle: const TextStyle(color: AdminColors.secondary, fontSize: 13),
        hintStyle: const TextStyle(color: AdminColors.muted, fontSize: 12),
        helperStyle: const TextStyle(color: AdminColors.muted, fontSize: 11),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AdminColors.hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AdminColors.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AdminColors.teal),
        ),
      ),
      dividerTheme: const DividerThemeData(color: AdminColors.hairline),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? AdminColors.teal
                : AdminColors.muted),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? AdminColors.tealBg
                : AdminColors.hairline),
      ),
      useMaterial3: true,
    );

/// Chip de estado de suscripción con el color del rediseño.
class AdminStatusChip extends StatelessWidget {
  final String? status;
  final int trialDaysLeft;
  const AdminStatusChip(
      {super.key, required this.status, this.trialDaysLeft = 0});

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
      'canceled' => (
          l.t('st_canceled'),
          AdminColors.muted,
          AdminColors.hairline
        ),
      _ => (l.t('st_inactive'), AdminColors.muted, AdminColors.hairline),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(9)),
      child: Text(label,
          style:
              TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: fg)),
    );
  }
}

/// showDialog captura el Theme del CONTEXT que le pasas; como el context de un
/// State está por ENCIMA del Theme(adminDarkTheme) que construye su build(),
/// los diálogos salían con el tema claro de la app. Este helper envuelve el
/// diálogo con la piel N SIEMPRE: úsalo en todo el panel en vez de showDialog.
Future<T?> showAdminDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (ctx) => Theme(
      data: adminDarkTheme(),
      child: Builder(builder: builder),
    ),
  );
}

/// Limita el ancho del contenido en pantallas anchas (web/PC) y lo centra, para
/// que las tarjetas no se vuelvan enormes. En móvil ocupa todo el ancho.
// Centra y limita el ancho del contenido del panel. RESPONSIVE: en móvil/estrecho
// respeta `maxWidth` (columna legible); en web/desktop ancho se ensancha para USAR
// el espacio en vez de dejar el contenido en una columna estrecha con mucho negro a
// los lados (los grids del panel son Wrap/GridView de columnas automáticas y refluyen
// solos a más columnas). Un único punto -> responsive en todas las pantallas admin.
Widget adminConstrained(Widget child, {double maxWidth = 720}) => LayoutBuilder(
      builder: (context, c) {
        final avail = c.maxWidth;
        final target = avail <= 760
            ? maxWidth
            : (avail >= 1200 ? 1160.0 : 920.0);
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: target),
            child: child,
          ),
        );
      },
    );

/// Decoración estándar de "tarjeta oscura" del panel.
BoxDecoration adminCardBox({Color? borderColor}) => BoxDecoration(
      color: AdminColors.card,
      border: borderColor == null
          ? null
          : Border.all(color: borderColor.withValues(alpha: .28)),
      borderRadius: BorderRadius.circular(12),
    );

/// KPI del rediseño: borde del color del módulo, etiqueta pequeña en
/// mayúsculas del mismo color y valor grande en blanco.
class AdminKpiTile extends StatelessWidget {
  final String label;
  final String value;
  final String sub;
  final Color color;
  final IconData? icon;
  final double? width;
  const AdminKpiTile(
      {super.key,
      required this.label,
      required this.value,
      this.sub = '',
      required this.color,
      this.icon,
      this.width});

  @override
  Widget build(BuildContext context) {
    final tile = Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: .28)),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 8.5, letterSpacing: 1.1, color: color)),
            ),
          ]),
          const SizedBox(height: 2),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AdminColors.text)),
          if (sub.isNotEmpty)
            Text(sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 9, color: AdminColors.muted)),
        ],
      ),
    );
    return tile;
  }
}

/// Píldora de filtro (seleccionada = fondo del color, texto oscuro).
class AdminPill extends StatelessWidget {
  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;
  const AdminPill(
      {super.key,
      required this.label,
      required this.selected,
      required this.color,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
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
    );
  }
}

/// Etiqueta pequeña en mayúsculas (FRAU, SUPORT…) con fondo oscuro del color.
class AdminTag extends StatelessWidget {
  final String text;
  final Color fg;
  final Color bg;
  const AdminTag(this.text, {super.key, required this.fg, required this.bg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(text.toUpperCase(),
          style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
              color: fg)),
    );
  }
}

/// AppBar estándar del panel (mismo fondo/estilo en todos los módulos).
/// Etiqueta legible del estado de suscripción (trialing -> "Periodo de prueba"...).
String adminStatusLabel(AppLocalizations l, String? s) => l.t(switch (s) {
      'active' => 'st_active',
      'trialing' => 'st_trial',
      'past_due' => 'st_past_due',
      'canceled' => 'st_canceled',
      _ => 'st_inactive',
    });

AppBar adminAppBar(String title, {List<Widget>? actions}) => AppBar(
      backgroundColor: AdminColors.bg,
      foregroundColor: AdminColors.text,
      elevation: 0,
      title: Text(title,
          style: const TextStyle(fontSize: 16, color: AdminColors.text)),
      actions: actions,
    );

/// Título de sección con acento de color (FRAU, IMPAGATS, EMPRESES…).
Widget adminSectionTitle(String text,
        {Color color = AdminColors.secondary, Widget? trailing}) =>
    Padding(
      padding: const EdgeInsets.fromLTRB(2, 14, 2, 8),
      child: Row(
        children: [
          Container(
              width: 3,
              height: 12,
              decoration: BoxDecoration(
                  color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 8),
          Text(text.toUpperCase(),
              style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: AdminColors.text)),
          if (trailing != null) ...[const Spacer(), trailing],
        ],
      ),
    );

/// Caja de "tarjeta con filas" separadas por hairline (listas cortas).
Widget adminRowsCard(List<Widget> rows) {
  final children = <Widget>[];
  for (var i = 0; i < rows.length; i++) {
    children.add(rows[i]);
    if (i < rows.length - 1) {
      children.add(
          const Divider(height: 1, thickness: 1, color: AdminColors.hairline));
    }
  }
  return Container(
    decoration: adminCardBox(),
    clipBehavior: Clip.antiAlias,
    child: Column(mainAxisSize: MainAxisSize.min, children: children),
  );
}

/// Campo de búsqueda estándar del panel.
Widget adminSearchField({
  required TextEditingController controller,
  required String hint,
  required ValueChanged<String> onChanged,
  required bool hasQuery,
  required VoidCallback onClear,
  Key? fieldKey,
}) =>
    TextField(
      key: fieldKey,
      controller: controller,
      onChanged: onChanged,
      style: const TextStyle(fontSize: 13, color: AdminColors.text),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 12, color: AdminColors.muted),
        prefixIcon:
            const Icon(Icons.search, size: 17, color: AdminColors.muted),
        filled: true,
        fillColor: AdminColors.card,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none),
        suffixIcon: hasQuery
            ? IconButton(
                icon:
                    const Icon(Icons.clear, size: 16, color: AdminColors.muted),
                onPressed: onClear)
            : null,
      ),
    );

/// Fila de lista estándar: leading (avatar/icono) · título (+badge) · subtítulo
/// · nota opcional · trailing (chip/valor) · chevron. Úsala en TODOS los módulos.
class AdminListRow extends StatelessWidget {
  final Widget? leading;
  final String title;
  final Widget? titleTrailing;
  final String? subtitle;
  final String? note;
  final Color noteColor;
  final Widget? trailing;
  final bool chevron;
  final VoidCallback? onTap;
  const AdminListRow({
    super.key,
    this.leading,
    required this.title,
    this.titleTrailing,
    this.subtitle,
    this.note,
    this.noteColor = AdminColors.blue,
    this.trailing,
    this.chevron = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 10)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: AdminColors.text)),
                  ),
                  if (titleTrailing != null) ...[
                    const SizedBox(width: 6),
                    titleTrailing!,
                  ],
                ]),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Text(subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 10.5, color: AdminColors.muted)),
                if (note != null && note!.isNotEmpty)
                  Text(note!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, color: noteColor)),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          if (chevron) ...[
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, size: 16, color: AdminColors.muted),
          ],
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
  }
}

/// Avatar cuadrado con las iniciales de la empresa.
class AdminInitialsAvatar extends StatelessWidget {
  final String name;
  final Color color;
  final Color bg;
  final double size;
  const AdminInitialsAvatar(
      {super.key,
      required this.name,
      this.color = AdminColors.purple,
      this.bg = AdminColors.purpleBg,
      this.size = 32});

  @override
  Widget build(BuildContext context) {
    final parts = name.trim().split(RegExp(r'\s+'));
    final initials = parts.length >= 2
        ? '${parts[0][0]}${parts[1][0]}'
        : (name.trim().isEmpty
            ? '?'
            : name.trim().substring(0, name.trim().length >= 2 ? 2 : 1));
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(size * .28)),
      alignment: Alignment.center,
      child: Text(initials.toUpperCase(),
          style: TextStyle(
              fontSize: size * .36, fontWeight: FontWeight.w600, color: color)),
    );
  }
}
