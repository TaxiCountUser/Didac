import 'dart:js_interop';

// Web: zona horaria del navegador (IANA, p. ej. 'Europe/Madrid'), la misma con la
// que la web enseña las horas de las carreras.
extension type _Dtf(JSObject _) implements JSObject {
  external _Opts resolvedOptions();
}

extension type _Opts(JSObject _) implements JSObject {
  external String get timeZone;
}

@JS('Intl.DateTimeFormat')
external _Dtf _dateTimeFormat();

String? webTimeZone() {
  try {
    return _dateTimeFormat().resolvedOptions().timeZone;
  } catch (_) {
    return null;
  }
}
