import 'package:flutter_test/flutter_test.dart';
import 'package:taxicount/util/workday.dart';

// Registro de jornada: entrada, pausas, salida, horas netas y km.
void main() {
  Map<String, dynamic> ev(String kind, String at, {int? km}) =>
      {'kind': kind, 'at': at, 'utc_offset_min': 120, 'km': km};

  test('jornada con una pausa de comida', () {
    final s = WorkdaySummary.fromShift({
      'status': 'closed',
      'started_at': '2026-10-14T06:00:00Z',
      'work_events': [
        ev('end', '2026-10-14T16:00:00Z', km: 32610), // desordenado a posta
        ev('start', '2026-10-14T06:00:00Z', km: 32442),
        ev('pause', '2026-10-14T11:00:00Z'),
        ev('resume', '2026-10-14T12:00:00Z'),
      ],
    });
    expect([s.start.hour, s.start.minute], [8, 0]); // 06:00 UTC = 08:00 en España
    expect(s.end!.hour, 18);
    expect(s.pauses.length, 1);
    expect([s.pauses.first.from.hour, s.pauses.first.to!.hour], [13, 14]);
    expect(s.worked(), const Duration(hours: 9)); // 10 h - 1 h de pausa
    expect(s.km, 168);
    expect(fmtWorked(s.worked()), '9 h 00 min');
  });

  test('finalizar estando en pausa: la pausa termina con la jornada', () {
    final s = WorkdaySummary.fromShift({
      'status': 'closed',
      'started_at': '2026-10-14T06:00:00Z',
      'work_events': [
        ev('start', '2026-10-14T06:00:00Z'),
        ev('pause', '2026-10-14T10:00:00Z'),
        ev('end', '2026-10-14T10:30:00Z'),
      ],
    });
    expect(s.pauses.single.to, isNotNull);
    expect(s.worked(), const Duration(hours: 4));
  });

  test('jornada abierta en pausa: cuenta hasta ahora', () {
    final s = WorkdaySummary.fromShift({
      'status': 'paused',
      'started_at': '2026-10-14T06:00:00Z',
      'work_events': [
        ev('start', '2026-10-14T06:00:00Z'),
        ev('pause', '2026-10-14T08:00:00Z'),
      ],
    });
    final now = DateTime.utc(2026, 10, 14, 9, 0);
    expect(s.pauses.single.to, isNull);
    expect(s.worked(now), const Duration(hours: 2));
    expect(s.pausedFor(now), const Duration(hours: 1));
  });
}
