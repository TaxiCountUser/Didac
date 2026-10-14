// Registro de jornada (mig. 093): cálculo de una jornada a partir de sus
// pulsaciones (start / pause / resume / end). Puro Dart (sin red) -> testeable.

/// Hora "de pared" de una pulsación: el instante (UTC) + la diferencia horaria
/// del móvil al pulsar. Así se ve a la hora local de quien la marcó, se mire
/// desde donde se mire (igual que las carreras, ver txWallTime).
DateTime workdayWall(String iso, dynamic offsetMin) {
  final utc = DateTime.parse(iso).toUtc();
  if (offsetMin is! num) return utc.toLocal();
  final w = utc.add(Duration(minutes: offsetMin.toInt()));
  return DateTime(w.year, w.month, w.day, w.hour, w.minute, w.second);
}

class WorkdayPause {
  final DateTime from;
  final DateTime? to; // null = pausa aún abierta
  const WorkdayPause(this.from, this.to);
  Duration length(DateTime now) => (to ?? now).difference(from);
}

class WorkdaySummary {
  final String status; // open | paused | closed
  final DateTime start; // hora de pared
  final DateTime? end;
  final List<WorkdayPause> pauses;
  final int? startKm, endKm;
  final bool corrected; // alguna pulsación corregida por el jefe
  // Instantes reales (UTC) para calcular duraciones sin líos de zona.
  final DateTime _startUtc;
  final DateTime? _endUtc;
  final List<(DateTime, DateTime?)> _pausesUtc;

  WorkdaySummary._(this.status, this.start, this.end, this.pauses, this.startKm, this.endKm,
      this.corrected, this._startUtc, this._endUtc, this._pausesUtc);

  /// Tiempo en pausa (las abiertas cuentan hasta [now] o hasta el final).
  Duration pausedFor([DateTime? now]) {
    final n = (now ?? DateTime.now()).toUtc();
    var d = Duration.zero;
    for (final (f, t) in _pausesUtc) {
      d += (t ?? _endUtc ?? n).difference(f);
    }
    return d;
  }

  /// Horas trabajadas = de la entrada a la salida (o a ahora) menos las pausas.
  Duration worked([DateTime? now]) {
    final n = (now ?? DateTime.now()).toUtc();
    final total = (_endUtc ?? n).difference(_startUtc) - pausedFor(n);
    return total.isNegative ? Duration.zero : total;
  }

  int? get km => (startKm != null && endKm != null && endKm! >= startKm!) ? endKm! - startKm! : null;

  /// A partir de una fila de work_shifts con su lista `work_events`.
  static WorkdaySummary fromShift(Map<String, dynamic> shift) {
    final evs = ((shift['work_events'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .toList()
      ..sort((a, b) => '${a['at']}'.compareTo('${b['at']}'));
    DateTime utc(Map e) => DateTime.parse('${e['at']}').toUtc();
    DateTime wall(Map e) => workdayWall('${e['at']}', e['utc_offset_min']);
    final startEv = evs.where((e) => e['kind'] == 'start').firstOrNull;
    final endEv = evs.where((e) => e['kind'] == 'end').lastOrNull;
    final startUtc = startEv != null ? utc(startEv) : DateTime.parse('${shift['started_at']}').toUtc();
    final startWall = startEv != null
        ? wall(startEv)
        : workdayWall('${shift['started_at']}', shift['utc_offset_min']);
    final pauses = <WorkdayPause>[];
    final pausesUtc = <(DateTime, DateTime?)>[];
    Map<String, dynamic>? open;
    for (final e in evs) {
      if (e['kind'] == 'pause') {
        open = e;
      } else if ((e['kind'] == 'resume' || e['kind'] == 'end') && open != null) {
        pauses.add(WorkdayPause(wall(open), wall(e)));
        pausesUtc.add((utc(open), utc(e)));
        open = null;
      }
    }
    if (open != null) {
      pauses.add(WorkdayPause(wall(open), null));
      pausesUtc.add((utc(open), null));
    }
    return WorkdaySummary._(
      '${shift['status']}',
      startWall,
      endEv != null ? wall(endEv) : null,
      pauses,
      (startEv?['km'] as num?)?.toInt() ?? (shift['start_km'] as num?)?.toInt(),
      (endEv?['km'] as num?)?.toInt() ?? (shift['end_km'] as num?)?.toInt(),
      evs.any((e) => e['corrected_at'] != null),
      startUtc,
      endEv != null ? utc(endEv) : null,
      pausesUtc,
    );
  }
}

/// "8 h 05 min" / "45 min".
String fmtWorked(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60;
  return h > 0 ? '$h h ${m.toString().padLeft(2, '0')} min' : '$m min';
}
