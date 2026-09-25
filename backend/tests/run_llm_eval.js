// Evaluación del parseo COMPLETO (determinista + LLM + merge), como en producción.
// Llama de verdad al LLM (Groq) con la clave del .env de la raíz: NO va en
// `npm test` (cuesta peticiones y depende de la red). Uso manual:
//
//   node tests/run_llm_eval.js            # todos los casos
//   node tests/run_llm_eval.js Figueres   # solo los que contienen "Figueres"
//
// Casos: parser_cases.json + llm_cases.json (frases que solo el LLM resuelve).
// Imprime la precisión por campo del determinista, del LLM solo y del resultado
// combinado, y los fallos del combinado.
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { parseTransactionText, needsLlm } from '../src/parser.js';
import { llmParse, mergeParsed } from '../src/llm_parser.js';
import { correctTranscript } from '../src/corrections.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

// Carga mínima del .env (raíz del repo, o backend/) sin dependencias.
for (const p of [join(__dirname, '..', '..', '.env'), join(__dirname, '..', '.env')]) {
  if (!existsSync(p)) continue;
  for (const line of readFileSync(p, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && process.env[m[1]] == null) process.env[m[1]] = m[2].replace(/^["']|["']$/g, '');
  }
}
const { OPENAI_API_KEY, OPENAI_BASE_URL, LLM_PARSE_MODEL } = process.env;
if (!OPENAI_API_KEY || !LLM_PARSE_MODEL) {
  console.error('Falta OPENAI_API_KEY / LLM_PARSE_MODEL en .env');
  process.exit(1);
}

const load = (f) => (existsSync(join(__dirname, f)) ? JSON.parse(readFileSync(join(__dirname, f), 'utf8')) : []);
const filter = process.argv[2]?.toLowerCase();
const cases = [...load('parser_cases.json'), ...load('llm_cases.json')]
  .filter((c) => !filter || c.text.toLowerCase().includes(filter));

const FIELDS = ['amount', 'category', 'type', 'payment_method', 'origin', 'destination', 'odometer_km', 'client_name'];
const normText = (s) => (s == null ? null : String(s).toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').trim());
function eq(field, got, exp) {
  if (field === 'amount') return exp == null ? got == null : Math.abs((got ?? NaN) - exp) < 0.001;
  if (['origin', 'destination', 'client_name'].includes(field)) return normText(got) === normText(exp);
  return (got ?? null) === exp;
}
const stats = { det: {}, llm: {}, merged: {} };
for (const k of Object.keys(stats)) for (const f of FIELDS) stats[k][f] = { ok: 0, total: 0 };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const failures = [];
let passed = 0;
let calls = 0;
let llmFailed = 0;

console.log(`Modelo: ${LLM_PARSE_MODEL} · ${cases.length} casos\n`);
for (const c of cases) {
  const text = correctTranscript(c.text);
  const det = parseTransactionText(text, c.vocab);
  // Igual que producción (parseSmart): el LLM solo entra si el determinista no
  // llega (needsLlm); LLM_ALWAYS=true lo fuerza en todas.
  const useLlm = process.env.LLM_ALWAYS === 'true' || needsLlm(text, det, c.vocab || {});
  let llm = Object.fromEntries(FIELDS.map((f) => [f, null]));
  let merged = det;
  if (useLlm) {
    calls++;
    try {
      llm = await llmParse(text, {
        apiKey: OPENAI_API_KEY, baseURL: OPENAI_BASE_URL || undefined, model: LLM_PARSE_MODEL, vocab: c.vocab,
      });
      merged = mergeParsed(llm, det);
    } catch (e) {
      llmFailed++;
      console.log(`  ! LLM falló en "${c.text}": ${e.message.slice(0, 160)}`);
    }
  }
  let allOk = true;
  const diffs = [];
  for (const [f, exp] of Object.entries(c.expected)) {
    for (const [k, r] of [['det', det], ['llm', llm], ['merged', merged]]) {
      if (k === 'llm' && !useLlm) continue; // "solo LLM" = solo las frases que lo consultan
      stats[k][f].total++;
      if (eq(f, r[f], exp)) stats[k][f].ok++;
      else if (k === 'merged') { allOk = false; diffs.push(`${f}: esperado=${JSON.stringify(exp)} obtenido=${JSON.stringify(r[f])} (det=${JSON.stringify(det[f])} llm=${JSON.stringify(llm[f])})`); }
    }
  }
  if (allOk) passed++; else failures.push({ text: c.text, diffs });
  process.stdout.write(allOk ? '.' : 'x');
  if (useLlm) await sleep(Number(process.env.LLM_EVAL_DELAY_MS || 2200)); // límite de peticiones/min de Groq
}

console.log('\n\n  campo            determinista   solo LLM   combinado');
for (const f of FIELDS) {
  if (!stats.merged[f].total) continue;
  const pct = (s) => (s.total ? `${((s.ok / s.total) * 100).toFixed(0)}%` : '—').padStart(4);
  console.log(`  ${f.padEnd(16)} ${pct(stats.det[f]).padStart(12)} ${pct(stats.llm[f]).padStart(10)} ${pct(stats.merged[f]).padStart(11)}   (${stats.merged[f].total})`);
}
if (failures.length) {
  console.log(`\nFallos del combinado (${failures.length}):`);
  for (const f of failures) {
    console.log(`  ✗ "${f.text}"`);
    for (const d of f.diffs) console.log(`      ${d}`);
  }
}
console.log(`\nLLM consultado en ${calls}/${cases.length} frases (${llmFailed} fallidas); el resto, solo determinista.`);
console.log(`COMBINADO: ${passed}/${cases.length} = ${((passed / cases.length) * 100).toFixed(1)}%`);
