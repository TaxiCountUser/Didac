import 'dart:math';

/// Motor del asistente virtual: un bot de preguntas frecuentes SIN IA (cero
/// tokens). Busca la pregunta del usuario en la base de conocimiento (semilla
/// `assets/assistant/kb.json` + lo que el admin enseña/el bot aprende, que llega
/// del backend) por palabras: normaliza, quita palabras vacías, aplica sinónimos,
/// recorta terminaciones y tolera faltas de ortografía (1–2 letras).
///
/// Puro Dart (sin Flutter) para poder probarlo con `flutter test`.

/// Una respuesta de la base de conocimiento.
class KbEntry {
  final String id;
  final String cat;
  final List<String> roles; // vacío = todos · 'driver' | 'owner'
  final Map<String, List<String>> q; // ejemplos de pregunta por idioma
  final Map<String, String> a; // respuesta por idioma
  final String? action; // pantalla a la que puede llevar (ver AssistantScreen)
  final String? tutorial; // URL del videotutorial (cuando exista)
  final List<String> related;
  final bool starter; // sale como sugerencia al abrir el chat

  const KbEntry({
    required this.id,
    this.cat = 'general',
    this.roles = const [],
    this.q = const {},
    this.a = const {},
    this.action,
    this.tutorial,
    this.related = const [],
    this.starter = false,
  });

  factory KbEntry.fromMap(String id, Map<String, dynamic> m) {
    Map<String, List<String>> qs = {};
    (m['q'] as Map? ?? {}).forEach((k, v) {
      qs['$k'] = (v is List ? v : '$v'.split('\n')).map((e) => '$e'.trim()).where((e) => e.isNotEmpty).toList();
    });
    final as = <String, String>{};
    (m['a'] as Map? ?? {}).forEach((k, v) => as['$k'] = '$v');
    return KbEntry(
      id: id,
      cat: (m['cat'] as String?) ?? 'general',
      roles: ((m['roles'] as List?) ?? const []).map((e) => '$e').toList(),
      q: qs,
      a: as,
      action: m['action'] as String?,
      tutorial: m['tutorial'] as String?,
      related: ((m['related'] as List?) ?? const []).map((e) => '$e').toList(),
      starter: m['starter'] == true,
    );
  }

  Map<String, dynamic> toMap() => {
        'cat': cat,
        'roles': roles,
        'q': q,
        'a': a,
        'action': action,
        'tutorial': tutorial,
        'related': related,
        if (starter) 'starter': true,
      };

  String answer(String lang) => a[lang] ?? a['es'] ?? '';

  /// Título corto (la primera pregunta de ejemplo) para chips/sugerencias.
  String title(String lang) {
    final l = q[lang] ?? q['es'] ?? const [];
    return l.isEmpty ? id : l.first;
  }

  bool forRole(String role) => roles.isEmpty || roles.contains(role);
}

class KbMatch {
  final KbEntry entry;
  final double score;
  const KbMatch(this.entry, this.score);
}

/// Base de conocimiento completa ya mezclada (semilla + admin + aprendido).
class AssistantKb {
  final Map<String, KbEntry> entries;
  final Map<String, Map<String, List<String>>> persona; // lang -> clave -> variantes
  final Map<String, Map<String, String>> synonyms; // lang -> palabra -> canónica
  final Map<String, Set<String>> stopwords; // lang -> palabras vacías
  final Map<String, String> learned; // frase normalizada -> entry id

  AssistantKb({
    required this.entries,
    this.persona = const {},
    this.synonyms = const {},
    this.stopwords = const {},
    this.learned = const {},
  });

  /// Construye la KB desde el JSON semilla y, si hay, lo del backend:
  /// `remote = {entries: [{id, data, active}], learned: [{phrase, entry_id}]}`.
  /// `excludeCats`: categorías que no se cargan (p. ej. 'suscripcion' en el build de
  /// Google Play, donde la app no puede explicar cómo pagar).
  factory AssistantKb.build(Map<String, dynamic> seed, [Map<String, dynamic>? remote,
      Set<String> excludeCats = const {}]) {
    final entries = <String, KbEntry>{};
    (seed['entries'] as Map? ?? {}).forEach((id, m) {
      entries['$id'] = KbEntry.fromMap('$id', (m as Map).cast<String, dynamic>());
    });
    for (final r in (remote?['entries'] as List? ?? const [])) {
      final id = '${r['id']}';
      if (r['active'] == false) {
        entries.remove(id); // el admin la ha ocultado
      } else if (r['data'] is Map) {
        entries[id] = KbEntry.fromMap(id, (r['data'] as Map).cast<String, dynamic>());
      }
    }
    if (excludeCats.isNotEmpty) entries.removeWhere((_, e) => excludeCats.contains(e.cat));
    final learned = <String, String>{};
    for (final l in (remote?['learned'] as List? ?? const [])) {
      final id = '${l['entry_id']}';
      if (entries.containsKey(id)) learned[normalize('${l['phrase']}')] = id;
    }
    Map<String, Map<String, T>> byLang<T>(dynamic m, T Function(dynamic) f) {
      final out = <String, Map<String, T>>{};
      (m as Map? ?? {}).forEach((lang, v) {
        out['$lang'] = (v as Map).map((k, x) => MapEntry('$k', f(x)));
      });
      return out;
    }
    final stop = <String, Set<String>>{};
    (seed['stopwords'] as Map? ?? {}).forEach((lang, v) {
      stop['$lang'] = (v as List).map((e) => normalize('$e')).toSet();
    });
    return AssistantKb(
      entries: entries,
      persona: byLang(seed['persona'], (x) => (x is List ? x : [x]).map((e) => '$e').toList()),
      synonyms: byLang(seed['synonyms'], (x) => normalize('$x')),
      stopwords: stop,
      learned: learned,
    );
  }

  /// Una frase de la "personalidad" del bot (elige variante al azar).
  String say(String lang, String key, [Map<String, String> args = const {}, Random? rnd]) {
    final list = persona[lang]?[key] ?? persona['es']?[key] ?? const <String>[];
    if (list.isEmpty) return '';
    var s = list[(rnd ?? _rnd).nextInt(list.length)];
    args.forEach((k, v) => s = s.replaceAll('{$k}', v));
    return s;
  }
}

final _rnd = Random();

const _accents = {
  'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a', 'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e',
  'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i', 'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o',
  'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u', 'ç': 'ç', 'ñ': 'ñ', 'l·l': 'll',
};

/// MISMA normalización que el backend (assistant.js → normPhrase), salvo ñ/ç que
/// el backend descompone (NFD) — da igual: el backend solo la usa para agrupar.
String normalize(String s) {
  var t = s.toLowerCase();
  _accents.forEach((k, v) => t = t.replaceAll(k, v));
  t = t.replaceAll(RegExp(r'[^a-z0-9ñç ]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length > 300 ? t.substring(0, 300) : t;
}

// Terminaciones (es/ca/en) que se recortan para comparar raíces: "cerrar",
// "cerrado", "cierro" -> "cerr"/"cierr" (estas dos casan por distancia 1).
const _suffixes = [
  'aciones', 'iciones', 'amente', 'imiento', 'acion', 'ament', 'mente', 'ando', 'iendo',
  'ados', 'adas', 'idos', 'idas', 'ing', 'ado', 'ada', 'ido', 'ida', 'ats', 'eix',
  'ar', 'er', 'ir', 'es', 'os', 'as', 'ed', 'en', 'o', 'a', 'e', 's',
];

String stem(String w) {
  if (w.length <= 4) return w;
  for (final s in _suffixes) {
    if (w.endsWith(s) && w.length - s.length >= 3) return w.substring(0, w.length - s.length);
  }
  return w;
}

int _lev(String a, String b) {
  if ((a.length - b.length).abs() > 2) return 3;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = <int>[i];
    for (var j = 1; j <= b.length; j++) {
      cur.add(min(min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)));
    }
    prev = cur;
  }
  return prev[b.length];
}

/// ¿Dos raíces "son la misma palabra"? Iguales, una prefijo de la otra (4+
/// letras) o a 1 letra (2 si son largas) — cubre faltas típicas al teclear.
bool similar(String a, String b) {
  if (a == b) return true;
  final m = min(a.length, b.length);
  if (m >= 4 && (a.startsWith(b) || b.startsWith(a))) return true;
  if (m >= 4 && _lev(a, b) <= 1) return true;
  if (m >= 7 && _lev(a, b) <= 2) return true;
  return false;
}

class AssistantEngine {
  final AssistantKb kb;
  // Por entrada: lista de "documentos" (raíces de cada pregunta de ejemplo).
  final Map<String, List<List<String>>> _docs = {};
  final Map<String, double> _idf = {};
  double _maxIdf = 1;
  final Set<String> _vocab = {}; // palabras (sin recortar) que conoce el bot

  AssistantEngine(this.kb) {
    final df = <String, int>{};
    var n = 0;
    for (final e in kb.entries.values) {
      e.q.forEach((_, qs) {
        for (final q in qs) {
          _vocab.addAll(normalize(q).split(' ').where((w) => w.length >= 4));
        }
      });
      final docs = <List<String>>[];
      e.q.forEach((lang, qs) {
        for (final q in qs) {
          final t = tokens(q, lang);
          if (t.isEmpty) continue;
          docs.add(t);
          n++;
          for (final w in t.toSet()) {
            df[w] = (df[w] ?? 0) + 1;
          }
        }
      });
      _docs[e.id] = docs;
    }
    // Las frases aprendidas también son ejemplos de su respuesta.
    kb.learned.forEach((phrase, id) {
      final t = tokens(phrase, 'es') + tokens(phrase, 'ca');
      if (t.isNotEmpty) _docs[id]?.add(t.toSet().toList());
    });
    df.forEach((w, c) => _idf[w] = log(1 + n / c));
    _maxIdf = _idf.values.fold(1.0, max);
  }

  /// Palabras significativas de una frase: normalizada, sin palabras vacías,
  /// con sinónimos aplicados y recortada a su raíz.
  List<String> tokens(String text, String lang) {
    final stop = kb.stopwords[lang] ?? kb.stopwords['es'] ?? const <String>{};
    final syn = {...?kb.synonyms['es'], ...?kb.synonyms[lang]};
    var t = ' ${normalize(text)} ';
    // Sinónimos de varias palabras primero ("dia de trabajo" -> "jornada").
    final multi = syn.keys.where((k) => k.contains(' ')).toList()..sort((a, b) => b.length - a.length);
    for (final k in multi) {
      t = t.replaceAll(' $k ', ' ${syn[k]} ');
    }
    final out = <String>[];
    for (var w in t.trim().split(' ')) {
      if (w.isEmpty || stop.contains(w)) continue;
      w = syn[w] ?? _spell(w, syn);
      if (w.length < 2) continue;
      for (final p in w.split(' ')) {
        out.add(stem(p));
      }
    }
    return out;
  }

  /// Corrige una falta de ortografía si la palabra no se conoce pero se parece
  /// (1 letra; 2 si es larga) a una del vocabulario: "cerar" -> "cerrar".
  String _spell(String w, Map<String, String> syn) {
    if (w.length < 4 || _vocab.isEmpty || _vocab.contains(w)) return w;
    for (final v in _vocab) {
      final d = _lev(w, v);
      if (d <= 1 || (d <= 2 && w.length >= 8)) return syn[v] ?? v;
    }
    return w;
  }

  /// Charla (hola, gracias, adiós…): solo si el mensaje ES eso, no si lo contiene
  /// ("hola, ¿cómo cierro la jornada?" debe ir a la jornada, no al saludo).
  double _smalltalk(KbEntry e, String norm) {
    final qw = norm.split(' ').where((w) => w.isNotEmpty).toList();
    if (qw.isEmpty) return 0;
    var best = 0.0;
    e.q.forEach((_, qs) {
      for (final ex in qs) {
        final ew = normalize(ex).split(' ');
        final qCov = qw.where((w) => ew.any((x) => similar(w, x))).length / qw.length;
        final eCov = ew.where((x) => qw.any((w) => similar(w, x))).length / ew.length;
        best = max(best, min(qCov, eCov));
      }
    });
    return best;
  }

  double _w(String tok) {
    // Palabra desconocida: peso bajo (no debe hundir una buena coincidencia,
    // p.ej. "oye", "porfa"), pero algo cuenta para no dar falsos positivos.
    final exact = _idf[tok];
    if (exact != null) return exact;
    for (final k in _idf.keys) {
      if (similar(tok, k)) return _idf[k]!;
    }
    // Un tercio de la más rara: una sola palabra que casa no debe bastar
    // para contestar con seguridad (mismo criterio que ProCount).
    return 0.35 * _maxIdf;
  }

  /// Puntúa cada entrada (0..1) y devuelve las mejores, de mayor a menor.
  /// `boost` = ids relacionados con lo último que se habló (contexto).
  List<KbMatch> search(String question, {String lang = 'es', String role = 'driver', Set<String> boost = const {}}) {
    final norm = normalize(question);
    final learnedId = kb.learned[norm];
    final qt = tokens(question, lang).toSet().toList();
    final results = <KbMatch>[];
    for (final e in kb.entries.values.where((e) => e.cat == 'smalltalk')) {
      final s = _smalltalk(e, norm);
      if (s >= 0.75) results.add(KbMatch(e, s));
    }
    if (qt.isEmpty && learnedId == null) return results..sort((a, b) => b.score.compareTo(a.score));
    final qWeights = {for (final t in qt) t: _w(t)};
    final qTotal = qWeights.values.fold(0.0, (a, b) => a + b);
    for (final e in kb.entries.values) {
      if (e.cat == 'smalltalk') continue;
      var best = 0.0;
      if (learnedId == e.id) best = 1.0;
      for (final doc in _docs[e.id] ?? const <List<String>>[]) {
        if (qTotal == 0) break;
        var qHit = 0.0;
        var hits = 0;
        for (final t in qt) {
          if (doc.any((d) => similar(t, d))) {
            qHit += qWeights[t]!;
            hits++;
          }
        }
        if (qHit == 0) continue;
        var dTotal = 0.0, dHit = 0.0;
        for (final d in doc.toSet()) {
          final w = _idf[d] ?? _maxIdf;
          dTotal += w;
          if (qt.any((t) => similar(t, d))) dHit += w;
        }
        var s = 0.6 * (qHit / qTotal) + 0.4 * (dTotal == 0 ? 0 : dHit / dTotal);
        if (hits * 2 < qt.length) s *= 0.8; // casa menos de la mitad: mejor preguntar
        if (s > best) best = s;
      }
      if (best <= 0) continue;
      if (!e.forRole(role)) best *= 0.75;
      if (boost.contains(e.id)) best = min(1.0, best * 1.12);
      results.add(KbMatch(e, best));
    }
    results.sort((a, b) => b.score.compareTo(a.score));
    return results;
  }
}
