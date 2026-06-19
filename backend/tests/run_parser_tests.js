// Runner del parser semántico. Carga parser_cases.json, ejecuta el parser
// y calcula la precisión por campo y global.
//
//   Uso:  node tests/run_parser_tests.js
//
// Métrica global = frases donde TODOS los campos esperados coinciden / total.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { parseTransactionText } from '../src/parser.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const cases = JSON.parse(readFileSync(join(__dirname, 'parser_cases.json'), 'utf8'));

const FIELDS = ['amount', 'category', 'type', 'payment_method'];
const fieldStats = Object.fromEntries(FIELDS.map((f) => [f, { ok: 0, total: 0 }]));

let passed = 0;
const failures = [];

function eq(field, got, exp) {
  if (field === 'amount') return Math.abs((got ?? NaN) - exp) < 0.001;
  return got === exp;
}

for (const c of cases) {
  const result = parseTransactionText(c.text);
  let allOk = true;
  const diffs = [];
  for (const [field, exp] of Object.entries(c.expected)) {
    fieldStats[field].total++;
    if (eq(field, result[field], exp)) {
      fieldStats[field].ok++;
    } else {
      allOk = false;
      diffs.push(`${field}: esperado=${JSON.stringify(exp)} obtenido=${JSON.stringify(result[field])}`);
    }
  }
  if (allOk) passed++;
  else failures.push({ text: c.text, diffs });
}

const total = cases.length;
const accuracy = (passed / total) * 100;

console.log('=== Resultados del parser ===\n');
for (const f of FIELDS) {
  const s = fieldStats[f];
  if (s.total === 0) continue;
  const pct = ((s.ok / s.total) * 100).toFixed(1);
  console.log(`  ${f.padEnd(15)} ${s.ok}/${s.total}  (${pct}%)`);
}
console.log('');

if (failures.length) {
  console.log(`Fallos (${failures.length}):`);
  for (const f of failures) {
    console.log(`  ✗ "${f.text}"`);
    for (const d of f.diffs) console.log(`      ${d}`);
  }
  console.log('');
}

console.log(`PRECISIÓN GLOBAL: ${passed}/${total} = ${accuracy.toFixed(1)}%`);

if (accuracy >= 95) {
  console.log('✅ Objetivo alcanzado (>=95%)');
  process.exit(0);
} else {
  console.log('❌ Por debajo del 95%');
  process.exit(1);
}
