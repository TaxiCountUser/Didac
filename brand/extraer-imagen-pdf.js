// Extrae las imagenes de un PDF y las guarda como PNG, sin dependencias.
// Reconstruye el PNG a mano: cabecera, IHDR, IDAT (los datos del PDF ya vienen
// en zlib, que es justo lo que PNG usa) e IEND.
const fs = require('fs');
const zlib = require('zlib');

const buf = fs.readFileSync(process.argv[2]);
const raw = buf.toString('latin1');
const out = process.argv[3];

const crcT = (() => { const t = []; for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
const crc = (b) => { let c = 0xffffffff; for (const x of b) c = crcT[(c ^ x) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
const chunk = (type, data) => {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'latin1'), data]);
  const c = Buffer.alloc(4); c.writeUInt32BE(crc(td));
  return Buffer.concat([len, td, c]);
};

let found = 0;
// Busca cada objeto que sea una imagen y quedate con su diccionario + datos
for (const m of raw.matchAll(/<<([^>]*?\/Subtype\s*\/Image[\s\S]*?)>>\s*stream\r?\n/g)) {
  const dict = m[1];
  const W = +(dict.match(/\/Width\s+(\d+)/) || [])[1];
  const H = +(dict.match(/\/Height\s+(\d+)/) || [])[1];
  const bpc = +(dict.match(/\/BitsPerComponent\s+(\d+)/) || [, 8])[1];
  const cs = (dict.match(/\/ColorSpace\s*\/?(\w+)/) || [, '?'])[1];
  const start = m.index + m[0].length;
  const end = raw.indexOf('endstream', start);
  let data;
  try { data = zlib.inflateSync(buf.subarray(start, end)); } catch { console.log('  (no se pudo descomprimir)'); continue; }
  found++;
  const comps = data.length / (W * H) ;
  console.log(`imagen ${found}: ${W}x${H} bpc=${bpc} espacio=${cs} datos=${data.length} -> ${comps.toFixed(2)} bytes/pixel`);

  // color type PNG: 0=gris, 2=RGB, 6=RGBA
  const ct = comps >= 3.9 ? 6 : comps >= 2.9 ? 2 : 0;
  const nch = ct === 6 ? 4 : ct === 2 ? 3 : 1;
  if (Math.abs(comps - nch) > 0.01) { console.log('  formato inesperado, me lo salto'); continue; }

  // PNG exige un byte de filtro (0) al principio de cada fila
  const rowLen = W * nch;
  const withFilter = Buffer.alloc((rowLen + 1) * H);
  for (let y = 0; y < H; y++) {
    withFilter[y * (rowLen + 1)] = 0;
    data.copy(withFilter, y * (rowLen + 1) + 1, y * rowLen, (y + 1) * rowLen);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(W, 0); ihdr.writeUInt32BE(H, 4);
  ihdr[8] = 8; ihdr[9] = ct; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  fs.writeFileSync(`${out}-${found}.png`, Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(withFilter)), chunk('IEND', Buffer.alloc(0)),
  ]));
  console.log(`  guardada en ${out}-${found}.png`);
}
if (!found) console.log('no encontre ninguna imagen');
