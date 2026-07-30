// Conversor Markdown -> HTML paginado -> PDF, sin dependencias.
// Cubre solo lo que usan los documentos de registro/: encabezados, tablas,
// listas, citas, negrita, cursiva, codigo en linea, enlaces y separadores.
//
//   node md2pdf.js <entrada.md> <salida.html>
//   msedge --headless=new --print-to-pdf=<salida.pdf> --no-pdf-header-footer <salida.html>

const fs = require('fs');

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// El codigo se aparta primero, para que su contenido no se reinterprete. El
// marcador va entre  porque un simple numero entre espacios chocaria con
// las fechas y cifras del propio texto.
function inline(s) {
  const code = [];
  s = s.replace(/`([^`]+)`/g, (_, c) => '' + (code.push(esc(c)) - 1) + '');
  s = esc(s);
  s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2">$1</a>');
  s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  s = s.replace(/(^|[^*])\*([^*]+)\*/g, '$1<em>$2</em>');
  return s.replace(/(\d+)/g, (_, i) => `<code>${code[i]}</code>`);
}

const isRule = (l) => /^\|[\s|:-]+\|$/.test(l);
const cells = (l) => l.replace(/^\||\|$/g, '').split('|').map((c) => inline(c.trim()));

// Cierto si la linea abre un bloque distinto (o esta vacia). Sirve para saber
// hasta donde llega un parrafo: el Markdown parte las lineas por ancho y hay
// que volver a juntarlas antes de formatear, o una negrita repartida entre dos
// lineas no se formatea nunca.
const opensBlock = (l) => !l.trim() || /^(#{1,4}\s|>|\|)/.test(l) ||
  /^\s*([-*]|\d+\.)\s+/.test(l) || /^(-{3,}|\*{3,})$/.test(l.trim());

function render(md) {
  const lines = md.split(/\r?\n/);
  const out = [];
  let i = 0, list = null;
  const closeList = () => { if (list) { out.push(`</${list}>`); list = null; } };

  while (i < lines.length) {
    const l = lines[i];

    if (!l.trim()) { closeList(); i++; continue; }

    const h = l.match(/^(#{1,4})\s+(.*)$/);
    if (h) { closeList(); out.push(`<h${h[1].length}>${inline(h[2])}</h${h[1].length}>`); i++; continue; }

    if (/^(-{3,}|\*{3,})$/.test(l.trim())) { closeList(); out.push('<hr>'); i++; continue; }

    if (l.startsWith('|') && isRule(lines[i + 1] || '')) {
      closeList();
      const head = cells(l);
      const rows = [];
      i += 2;
      while (i < lines.length && lines[i].startsWith('|')) rows.push(cells(lines[i++]));
      out.push('<table><thead><tr>' + head.map((c) => `<th>${c}</th>`).join('') + '</tr></thead><tbody>' +
        rows.map((r) => '<tr>' + r.map((c) => `<td>${c}</td>`).join('') + '</tr>').join('') +
        '</tbody></table>');
      continue;
    }

    if (/^>/.test(l)) {
      closeList();
      const buf = [];
      while (i < lines.length && /^>/.test(lines[i])) buf.push(lines[i++].replace(/^>\s?/, ''));
      out.push(`<blockquote>${inline(buf.join(' '))}</blockquote>`);
      continue;
    }

    const li = l.match(/^\s*([-*]|\d+\.)\s+(.*)$/);
    if (li) {
      const want = /^\d/.test(li[1]) ? 'ol' : 'ul';
      if (list !== want) { closeList(); out.push(`<${want}>`); list = want; }
      const buf = [li[2]];
      i++;
      while (i < lines.length && !opensBlock(lines[i])) buf.push(lines[i++].trim());
      out.push(`<li>${inline(buf.join(' '))}</li>`);
      continue;
    }

    closeList();
    const buf = [];
    while (i < lines.length && !opensBlock(lines[i])) buf.push(lines[i++].trim());
    out.push(`<p>${inline(buf.join(' '))}</p>`);
  }
  closeList();
  return out.join('\n');
}

const CSS = `
@page { size: A4; margin: 18mm 16mm 16mm; }
body { font-family: "Segoe UI", Helvetica, Arial, sans-serif; font-size: 10.5pt; line-height: 1.5; color: #1c1c1c; margin: 0; }
h1 { font-size: 19pt; margin: 0 0 4pt; letter-spacing: -.2pt; }
h2 { font-size: 13pt; margin: 20pt 0 6pt; padding-bottom: 3pt; border-bottom: 1px solid #ddd; page-break-after: avoid; }
h3 { font-size: 11.5pt; margin: 14pt 0 4pt; page-break-after: avoid; }
p { margin: 0 0 7pt; text-align: justify; }
ul, ol { margin: 0 0 8pt; padding-left: 17pt; }
li { margin-bottom: 3pt; }
table { border-collapse: collapse; width: 100%; margin: 8pt 0 12pt; font-size: 9.5pt; page-break-inside: avoid; }
th, td { border: 1px solid #d8d8d8; padding: 4.5pt 6pt; text-align: left; vertical-align: top; }
th { background: #f4f2ef; font-weight: 600; }
blockquote { margin: 8pt 0; padding: 7pt 11pt; background: #faf8f5; border-left: 3px solid #FFC107; font-size: 10pt; }
blockquote p { margin: 0; }
code { font-family: Consolas, "Courier New", monospace; font-size: 9pt; background: #f2f0ed; padding: .5pt 3pt; border-radius: 2.5pt; }
a { color: #1c1c1c; text-decoration: underline; }
hr { border: 0; border-top: 1px solid #e2e2e2; margin: 14pt 0; }
strong { font-weight: 600; }
`;

const [, , src, dst] = process.argv;
if (!src || !dst) { console.error('uso: node md2pdf.js <entrada.md> <salida.html>'); process.exit(1); }
const md = fs.readFileSync(src, 'utf8');
const title = (md.match(/^#\s+(.*)$/m) || [, 'TaxiCount'])[1];
fs.writeFileSync(dst,
  `<!doctype html><html lang="es"><head><meta charset="utf-8"><title>${esc(title)}</title><style>${CSS}</style></head><body>${render(md)}</body></html>`);
console.log('ok ' + dst);
