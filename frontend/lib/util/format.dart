import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Iconos por categoría (coinciden con kCategories de la entrada manual).
const kCategoryIcons = <String, IconData>{
  'gasolina': Icons.local_gas_station,
  'gasoil': Icons.local_gas_station,
  'taller': Icons.build,
  'peaje': Icons.toll,
  'parking': Icons.local_parking,
  'lavado': Icons.local_car_wash,
  'compra': Icons.shopping_cart,
  'ingreso_tarjeta': Icons.credit_card,
  'otros': Icons.more_horiz,
};

/// Etiqueta legible de una categoría.
const kCategoryLabels = <String, String>{
  'gasolina': 'Gasolina',
  'gasoil': 'Gasoil',
  'taller': 'Taller',
  'peaje': 'Peaje',
  'parking': 'Parking',
  'lavado': 'Lavado',
  'compra': 'Compra',
  'ingreso_tarjeta': 'Ingreso',
  'otros': 'Otros',
};

IconData categoryIcon(String? cat) => kCategoryIcons[cat] ?? Icons.receipt_long;
String categoryLabel(String? cat) => kCategoryLabels[cat] ?? (cat ?? 'Sin categoría');

/// Primera letra en mayúscula (resto sin tocar). P. ej. "gitaxi" -> "Gitaxi".
String capitalizeFirst(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// Nombre de cliente/empresa para mostrar: empresa capitalizada o "Particular".
String clientDisplay(Map<String, dynamic> tx) {
  final c = (tx['client_name'] as String?)?.trim();
  return (c != null && c.isNotEmpty) ? capitalizeFirst(c) : 'Particular';
}

/// Título de una transacción para listas/detalle: en una carrera (ingreso),
/// la empresa nombrada (capitalizada) o "Particular"; en un gasto, la categoría.
String txTitle(Map<String, dynamic> tx) {
  if (tx['type'] == 'income') return clientDisplay(tx);
  return categoryLabel(tx['category'] as String?);
}

/// Icono de una transacción: taxi para carreras, icono de categoría para gastos.
IconData txIcon(Map<String, dynamic> tx) =>
    tx['type'] == 'income' ? Icons.local_taxi : categoryIcon(tx['category'] as String?);

/// Trayecto "origen → destino" de una carrera, o null si no aplica/está vacío.
String? tripRoute(Map<String, dynamic> tx) {
  if (tx['type'] != 'income') return null;
  final o = (tx['origin'] as String?)?.trim();
  final d = (tx['destination'] as String?)?.trim();
  if ((o == null || o.isEmpty) && (d == null || d.isEmpty)) return null;
  return '${o?.isNotEmpty == true ? o : '—'} → ${d?.isNotEmpty == true ? d : '—'}';
}

final _money = NumberFormat.currency(locale: 'es_ES', symbol: '€', decimalDigits: 2);
String money(num v) => _money.format(v);

final _dateFmt = DateFormat('d MMM yyyy', 'es');
final _dateTimeFmt = DateFormat('d MMM yyyy · HH:mm', 'es');
String fmtDate(DateTime d) => _dateFmt.format(d.toLocal());
String fmtDateTime(DateTime d) => _dateTimeFmt.format(d.toLocal());

/// Color por tipo: verde (ingreso) / rojo (gasto).
Color typeColor(String? type) =>
    type == 'income' ? const Color(0xFF2E7D32) : const Color(0xFFC62828);

/// Parsea created_at (puede venir como String ISO o DateTime).
DateTime parseCreatedAt(dynamic v) {
  if (v is DateTime) return v;
  return DateTime.parse(v as String);
}

/// Nombre legible del conductor a partir de la relación embebida `users`.
String driverName(Map<String, dynamic> tx) {
  final u = tx['users'];
  if (u is Map) {
    final n = u['name'] as String?;
    if (n != null && n.isNotEmpty) return n;
    final e = u['email'] as String?;
    if (e != null && e.isNotEmpty) return e;
  }
  return 'Conductor';
}

/// Clave i18n del ROL de quien envió un mensaje (según la relación `users`):
/// admin > propietario (jefe) > conductor.
String senderRoleKey(Map<String, dynamic> m) {
  final u = m['users'];
  if (u is Map) {
    if (u['is_admin'] == true) return 'role_admin';
    if (u['role'] == 'owner') return 'role_owner';
  }
  return 'role_driver';
}

/// Descripción legible del vehículo a partir de la relación embebida `vehicles`.
String? vehicleLabel(Map<String, dynamic> tx) {
  final v = tx['vehicles'];
  if (v is Map) {
    final plate = v['license_plate'] as String?;
    final model = v['model'] as String?;
    if (plate != null && model != null && model.isNotEmpty) return '$plate · $model';
    return plate ?? model;
  }
  return null;
}
