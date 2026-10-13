import 'package:flutter_test/flutter_test.dart';
import 'package:taxicount/util/format.dart';

// Hora de cada carrera tal como se apuntó (mig. 091), se mire desde donde se mire.
void main() {
  test('carrera de México (−360) sale a las 08:15 desde cualquier sitio', () {
    final w = txWallTime({'created_at': '2026-10-01T14:15:00Z', 'utc_offset_min': -360});
    expect([w.year, w.month, w.day, w.hour, w.minute], [2026, 10, 1, 8, 15]);
    expect(w.isUtc, isFalse); // fmtDateTime/toLocal no la mueven
  });

  test('carrera de España a las 00:30 (verano, +120) es del día 2', () {
    final w = txWallTime({'created_at': '2026-10-01T22:30:00Z', 'utc_offset_min': 120});
    expect([w.day, w.hour, w.minute], [2, 0, 30]);
  });

  test('editar: la hora de pared vuelve al mismo instante con su diferencia', () {
    final tx = {'created_at': '2026-10-01T14:15:00.000Z', 'utc_offset_min': -360};
    final back = wallToUtc(txWallTime(tx), -360);
    expect(back.toIso8601String(), '2026-10-01T14:15:00.000Z');
    // Cambiar la hora a las 09:00 (México) = 15:00 UTC.
    expect(wallToUtc(DateTime(2026, 10, 1, 9, 0), -360).toIso8601String(), '2026-10-01T15:00:00.000Z');
  });

  test('carrera antigua (sin diferencia): hora del móvil, como siempre', () {
    final w = txWallTime({'created_at': '2026-10-01T06:10:00Z'});
    expect(w, DateTime.parse('2026-10-01T06:10:00Z').toLocal());
  });
}
