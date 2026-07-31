// Convierte texto compuesto con una fuente TrueType en trazados SVG.
// Lee los contornos de la tabla glyf (curvas cuadraticas) y los emite como
// path, de modo que el resultado no depende de tener la fuente instalada.
//
//   node ttf-a-trazados.js <fuente.ttf> <texto> <salida.svg> [alturaMayuscula] [interletraje]
//
// El interletraje va en las mismas unidades que la altura de mayuscula y se
// suma al avance de cada letra: negativo apreta, positivo abre.
const fs = require('fs');

const f = fs.readFileSync(process.argv[2]);
const TEXT = process.argv[3];
const OUT = process.argv[4];
const CAP = +(process.argv[5] || 700); // alto de mayuscula deseado, en unidades del SVG

// --- tablas
const tables = {};
const n = f.readUInt16BE(4);
for (let i = 0; i < n; i++) {
  const o = 12 + i * 16;
  tables[f.toString('latin1', o, o + 4).trim()] = { off: f.readUInt32BE(o + 8), len: f.readUInt32BE(o + 12) };
}
const upm = f.readUInt16BE(tables.head.off + 18);
const longLoca = f.readInt16BE(tables.head.off + 50) === 1;
const numGlyphs = f.readUInt16BE(tables.maxp.off + 4);
const numHMetrics = f.readUInt16BE(tables.hhea.off + 34);

// --- cmap formato 4
function cmapLookup() {
  const base = tables.cmap.off;
  const nt = f.readUInt16BE(base + 2);
  let sub = null;
  for (let i = 0; i < nt; i++) {
    const o = base + 4 + i * 8;
    const off = f.readUInt32BE(o + 4);
    if (f.readUInt16BE(base + off) === 4) { sub = base + off; break; }
  }
  if (!sub) throw new Error('sin cmap formato 4');
  const segX2 = f.readUInt16BE(sub + 6), seg = segX2 / 2;
  const ends = sub + 14, starts = ends + segX2 + 2, deltas = starts + segX2, ranges = deltas + segX2;
  return (cp) => {
    for (let i = 0; i < seg; i++) {
      if (f.readUInt16BE(ends + i * 2) < cp) continue;
      const st = f.readUInt16BE(starts + i * 2);
      if (st > cp) return 0;
      const ro = f.readUInt16BE(ranges + i * 2);
      if (ro === 0) return (cp + f.readInt16BE(deltas + i * 2)) & 0xffff;
      const gi = f.readUInt16BE(ranges + i * 2 + ro + (cp - st) * 2);
      return gi ? (gi + f.readInt16BE(deltas + i * 2)) & 0xffff : 0;
    }
    return 0;
  };
}
const gid = cmapLookup();
const advance = (g) => f.readUInt16BE(tables.hmtx.off + Math.min(g, numHMetrics - 1) * 4);
const locaAt = (i) => longLoca ? f.readUInt32BE(tables.loca.off + i * 4) : f.readUInt16BE(tables.loca.off + i * 2) * 2;

// --- contornos de un glifo -> comandos SVG (cuadraticas)
function glyphPath(g, dx, dy, scale) {
  const s = locaAt(g), e = locaAt(g + 1);
  if (s === e) return '';
  let o = tables.glyf.off + s;
  const nc = f.readInt16BE(o);
  o += 10;
  if (nc < 0) { // compuesto: resuelve los componentes
    let out = '';
    for (;;) {
      const flags = f.readUInt16BE(o), idx = f.readUInt16BE(o + 2); o += 4;
      let a1, a2;
      if (flags & 1) { a1 = f.readInt16BE(o); a2 = f.readInt16BE(o + 2); o += 4; }
      else { a1 = f.readInt8(o); a2 = f.readInt8(o + 1); o += 2; }
      if (flags & 8) o += 2; else if (flags & 0x40) o += 4; else if (flags & 0x80) o += 8;
      out += glyphPath(idx, dx + a1 * scale, dy - a2 * scale, scale);
      if (!(flags & 0x20)) break;
    }
    return out;
  }
  const endPts = [];
  for (let i = 0; i < nc; i++) { endPts.push(f.readUInt16BE(o)); o += 2; }
  o += 2 + f.readUInt16BE(o); // salta las instrucciones
  const total = endPts[nc - 1] + 1;
  const flags = [];
  while (flags.length < total) {
    const fl = f.readUInt8(o++); flags.push(fl);
    if (fl & 8) { let r = f.readUInt8(o++); while (r--) flags.push(fl); }
  }
  const xs = [], ys = [];
  let v = 0;
  for (let i = 0; i < total; i++) {
    const fl = flags[i];
    if (fl & 2) { const d = f.readUInt8(o++); v += (fl & 16) ? d : -d; }
    else if (!(fl & 16)) { v += f.readInt16BE(o); o += 2; }
    xs.push(v);
  }
  v = 0;
  for (let i = 0; i < total; i++) {
    const fl = flags[i];
    if (fl & 4) { const d = f.readUInt8(o++); v += (fl & 32) ? d : -d; }
    else if (!(fl & 32)) { v += f.readInt16BE(o); o += 2; }
    ys.push(v);
  }
  // y invertida: en la fuente crece hacia arriba, en SVG hacia abajo
  const P = (i) => ({ x: dx + xs[i] * scale, y: dy - ys[i] * scale, on: !!(flags[i] & 1) });
  const mid = (a, b) => ({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 });
  const r = (n) => Math.round(n * 10) / 10;
  let d = '', start = 0;
  for (let c = 0; c < nc; c++) {
    const end = endPts[c], len = end - start + 1;
    const pt = (i) => P(start + ((i % len) + len) % len);
    let i0 = 0;
    while (i0 < len && !pt(i0).on) i0++;
    let cur = i0 < len ? pt(i0) : mid(pt(0), pt(1));
    d += `M${r(cur.x)},${r(cur.y)}`;
    for (let k = 1; k <= len; k++) {
      const p = pt(i0 + k);
      if (p.on) { d += `L${r(p.x)},${r(p.y)}`; cur = p; }
      else {
        const nx = pt(i0 + k + 1);
        const endp = nx.on ? nx : mid(p, nx);
        d += `Q${r(p.x)},${r(p.y)} ${r(endp.x)},${r(endp.y)}`;
        cur = endp;
        if (nx.on) k++;
      }
    }
    d += 'Z';
    start = end + 1;
  }
  return d;
}

// --- componer el texto
const capH = f.readInt16BE(tables['OS/2'].off + 88) || 700; // sCapHeight
const scale = CAP / capH;
const TRACK = +(process.argv[6] || 0);
let x = 0, d = '';
const chars = [...TEXT];
chars.forEach((ch, i) => {
  const g = gid(ch.codePointAt(0));
  d += glyphPath(g, x, 0, scale);
  x += advance(g) * scale;
  if (i < chars.length - 1) x += TRACK; // el ultimo no arrastra aire sobrante
});
const asc = f.readInt16BE(tables.hhea.off + 4) * scale;
const desc = f.readInt16BE(tables.hhea.off + 6) * scale;
const H = Math.round(asc - desc);
const W = Math.round(x);
fs.writeFileSync(OUT, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 ${Math.round(-asc)} ${W} ${H}" width="${W}" height="${H}">
  <title>${TEXT}</title>
  <path fill="#1E1B16" d="${d}"/>
</svg>\n`);
console.log(`"${TEXT}" -> ${OUT}  |  ${W}x${H}, alto de mayuscula ${CAP}, ${d.length} bytes de trazado`);
