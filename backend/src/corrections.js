// ============================================================
// TaxiCount - Correcciones de transcripción de voz.
// Whisper a veces parte nombres propios locales: "Museu Dalí" -> "museu de lí",
// y ese "de" rompe el origen/destino. Aquí normalizamos términos habituales
// ANTES de interpretar la frase. Ampliable con la variable de entorno
// TRANSCRIBE_CORRECTIONS (formato "mal=>bien;mal2=>bien2").
// ============================================================

// Reglas base (regex, sin distinguir mayúsculas/acentos donde toca).
// Nota: en JS \b no funciona junto a letras acentuadas (í), por eso usamos un
// lookahead de "fin de palabra" (espacio, fin o puntuación).
const END = '(?=\\s|$|[.,;:!?)])';
const BASE_RULES = [
  // "museu/museo de lí|li" -> "Museu Dalí"
  [new RegExp(`\\bmuse[uo]\\s+de\\s+l[ií]${END}`, 'gi'), 'Museu Dalí'],
  // "de lí" suelto (Whisper parte Dalí) -> "Dalí"
  [new RegExp(`\\bde\\s+l[ií]${END}`, 'gi'), 'Dalí'],
  // "dali"/"dalí" -> "Dalí" (acento correcto)
  [new RegExp(`\\bdal[ií]${END}`, 'gi'), 'Dalí'],
  // Variantes de Figueres
  [/\bfiguer[ae]s\b/gi, 'Figueres'],
];

// Reglas extra desde entorno: "mal=>bien;otro=>bien" (texto literal, ci).
function envRules() {
  const raw = process.env.TRANSCRIBE_CORRECTIONS || '';
  return raw
    .split(';')
    .map((p) => p.split('=>'))
    .filter((p) => p.length === 2 && p[0].trim())
    .map(([from, to]) => [new RegExp(from.trim().replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi'), to.trim()]);
}

export function correctTranscript(text) {
  let s = text || '';
  for (const [re, to] of [...BASE_RULES, ...envRules()]) s = s.replace(re, to);
  return s.replace(/\s+/g, ' ').trim();
}

export default correctTranscript;
