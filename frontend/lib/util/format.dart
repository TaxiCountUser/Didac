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
