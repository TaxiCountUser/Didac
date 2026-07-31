// Vectoriza una forma bitonal: marching squares para sacar los contornos,
// Douglas-Peucker para quitar puntos redundantes y salida en SVG.
// Sin dependencias. Uso: node trace.js <pdf> <indiceBanda> <salida.svg>
const fs = require('fs');
const zlib = require('zlib');

const buf = fs.readFileSync(process.argv[2]);
const raw = buf.toString('latin1');

// La mascara de transparencia es la imagen DeviceGray
let gray = null, W = 0, H = 0;
for (const m of raw.matchAll(/<<([^>]*?\/Subtype\s*\/Image[\s\S]*?)>>\s*stream\r?\n/g)) {
  const d = m[1];
  if (!/DeviceGray/.test(d)) continue;
  W = +d.match(/\/Width\s+(\d+)/)[1];
  H = +d.match(/\/Height\s+(\d+)/)[1];
  const s = m.index + m[0].length;
  gray = zlib.inflateSync(buf.subarray(s, raw.indexOf('endstream', s)));
  break;
}
if (!gray) { console.error('no encontre la mascara en gris'); process.exit(1); }
const on = (x, y) => x >= 0 && y >= 0 && x < W && y < H && gray[y * W + x] > 127;

// Localiza las bandas horizontales con contenido (cada monograma)
const rowHas = [];
for (let y = 0; y < H; y++) { let c = 0; for (let x = 0; x < W; x++) if (on(x, y)) { c = 1; break; } rowHas.push(c); }
const bands = [];
for (let y = 0; y < H; y++) {
  if (rowHas[y] && (y === 0 || !rowHas[y - 1])) bands.push({ y0: y });
  if (rowHas[y] && (y === H - 1 || !rowHas[y + 1])) bands[bands.length - 1].y1 = y;
}
console.log('bandas con contenido:', bands.map((b, i) => `${i}:${b.y0}-${b.y1}`).join('  '));

const band = bands[+process.argv[3]];
if (!band) { console.error('banda inexistente'); process.exit(1); }
// columnas de esa banda
let x0 = W, x1 = 0;
for (let y = band.y0; y <= band.y1; y++) for (let x = 0; x < W; x++) if (on(x, y)) { if (x < x0) x0 = x; if (x > x1) x1 = x; }
const P = 6; // margen
const cx0 = x0 - P, cy0 = band.y0 - P, cw = x1 - x0 + 1 + 2 * P, ch = band.y1 - band.y0 + 1 + 2 * P;
console.log(`banda ${process.argv[3]}: recorte ${cw}x${ch} en (${cx0},${cy0})`);

const px = (x, y) => on(cx0 + x, cy0 + y);

// --- marching squares: cada celda aporta segmentos entre puntos medios de sus lados
const key = (p) => `${p[0]},${p[1]}`;
const segs = new Map(); // origen -> destino
const add = (a, b) => { segs.set(key(a), { a, b }); };
for (let y = -1; y < ch; y++) {
  for (let x = -1; x < cw; x++) {
    const tl = px(x, y), tr = px(x + 1, y), br = px(x + 1, y + 1), bl = px(x, y + 1);
    const c = (tl ? 8 : 0) | (tr ? 4 : 0) | (br ? 2 : 0) | (bl ? 1 : 0);
    const N = [x + 0.5, y], E = [x + 1, y + 0.5], S = [x + 0.5, y + 1], Wp = [x, y + 0.5];
    // sentido: el relleno queda a la izquierda
    switch (c) {
      case 1: add(Wp, S); break;      case 2: add(S, E); break;
      case 3: add(Wp, E); break;      case 4: add(E, N); break;
      case 5: add(Wp, N); add(E, S); break;
      case 6: add(S, N); break;       case 7: add(Wp, N); break;
      case 8: add(N, Wp); break;      case 9: add(N, S); break;
      case 10: add(N, E); add(S, Wp); break;
      case 11: add(N, E); break;      case 12: add(E, Wp); break;
      case 13: add(E, S); break;      case 14: add(S, Wp); break;
    }
  }
}

// --- estirar los segmentos en bucles cerrados
const loops = [];
while (segs.size) {
  const first = segs.values().next().value;
  const loop = [first.a];
  let cur = first;
  while (cur) {
    segs.delete(key(cur.a));
    loop.push(cur.b);
    const nxt = segs.get(key(cur.b));
    if (!nxt || key(nxt.a) === key(first.a)) { if (nxt) segs.delete(key(nxt.a)); break; }
    cur = nxt;
  }
  if (loop.length > 12) loops.push(loop);
}
console.log('contornos encontrados:', loops.length, '(uno exterior + las contraformas)');

// --- Douglas-Peucker
function dp(pts, eps) {
  if (pts.length < 3) return pts;
  let max = 0, idx = 0;
  const [ax, ay] = pts[0], [bx, by] = pts[pts.length - 1];
  const dx = bx - ax, dy = by - ay, den = Math.hypot(dx, dy) || 1;
  for (let i = 1; i < pts.length - 1; i++) {
    const d = Math.abs(dy * pts[i][0] - dx * pts[i][1] + bx * ay - by * ax) / den;
    if (d > max) { max = d; idx = i; }
  }
  if (max <= eps) return [pts[0], pts[pts.length - 1]];
  return [...dp(pts.slice(0, idx + 1), eps).slice(0, -1), ...dp(pts.slice(idx), eps)];
}

// En un bucle cerrado el primer y el ultimo punto coinciden, asi que la recta
// que los une es degenerada y Douglas-Peucker se lo cargaria entero. Hay que
// partirlo por el punto mas lejano al inicio y simplificar cada mitad.
function dpLoop(l, eps) {
  let far = 0, fd = -1;
  for (let i = 1; i < l.length; i++) {
    const d = Math.hypot(l[i][0] - l[0][0], l[i][1] - l[0][1]);
    if (d > fd) { fd = d; far = i; }
  }
  return [...dp(l.slice(0, far + 1), eps).slice(0, -1), ...dp(l.slice(far), eps).slice(0, -1)];
}

const EPS = +(process.argv[5] || 1.2);
const paths = loops.map((l) => {
  const s = dpLoop(l, EPS);
  return 'M' + s.map(([x, y]) => `${(+x).toFixed(1)},${(+y).toFixed(1)}`).join('L') + 'Z';
});
const pts = paths.reduce((n, p) => n + p.split('L').length, 0);
console.log('puntos tras simplificar:', pts);

fs.writeFileSync(process.argv[4],
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${cw} ${ch}" width="${cw}" height="${ch}">
  <title>Monograma CT vectorizado</title>
  <path fill="#1E1B16" fill-rule="evenodd" d="${paths.join('')}"/>
</svg>\n`);
console.log('escrito', process.argv[4]);
