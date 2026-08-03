// Arma hoja-de-marca.png, el resumen visual de la identidad.
//   node brand/hoja-de-marca.js
// Lee los SVG ya generados, asi que hay que lanzarlo DESPUES de generar-marca.js.
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');

const HERE = __dirname;
const FECHA = '3 de agosto de 2026';
const AMBAR = '#FFC107', NEGRO = '#1E1B16', CREMA = '#FEF7EC';

const EDGE = [
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
].find((p) => fs.existsSync(p));
if (!EDGE) { console.error('No encuentro msedge.exe'); process.exit(1); }

// Devuelve el SVG con otro tamaño, sin tocar su viewBox.
const svg = (f, w, h) => fs.readFileSync(path.join(HERE, f), 'utf8')
  .replace(/<\?xml[^>]*>/, '')
  .replace(/width="[\d.]+" height="[\d.]+"/, `width="${w}" height="${h}"`);

const MIXTA = 'taxicount-marca-mixta-color.svg';
const bloque = (t, cuerpo) => `<div class="b"><div class="h">${t}</div>${cuerpo}</div>`;
const pieza = (f, w, h, pie) => `<div class="p">${svg(f, w, h)}<div class="c">${pie}</div></div>`;

const html = `<style>
body{font-family:Segoe UI,sans-serif;margin:0;padding:26px 26px 8px;background:#fff;color:${NEGRO}}
h1{font-size:20px;margin:0 0 4px}
.sub{font-size:11.5px;color:#999;margin-bottom:4px}
.b{border-top:1px solid #eee;padding:14px 0 4px}
.h{font-size:10px;letter-spacing:1.6px;color:#aaa;font-weight:700;margin-bottom:10px}
.osc{background:${NEGRO};border-radius:8px;padding:14px 18px;display:inline-block;margin-top:12px}
.fila{display:flex;align-items:flex-end;gap:30px;flex-wrap:wrap}
.p{text-align:center}
.c{font-size:10px;color:#bbb;margin-top:5px}
.col{display:flex;gap:12px;margin-top:2px}
.s{width:80px}.s i{display:block;height:44px;border-radius:5px;border:1px solid #0001}
.s b{display:block;font-size:9.5px;color:#999;font-weight:400;margin-top:5px}
</style>
<h1>TaxiCount — identidad de marca</h1>
<div class="sub">${FECHA} · ligadura CT del titular + Lora vectorizada · archivos en brand/</div>

${bloque('MARCA MIXTA — LA QUE SE PRESENTA EN LA OEPM', svg(MIXTA, 600, 118))}

${bloque('BLANCO Y NEGRO · FONDO OSCURO',
  svg('taxicount-marca-mixta-negro.svg', 380, 75) +
  `<div class="osc">${svg('taxicount-marca-mixta-fondo-oscuro.svg', 400, 79)}</div>`)}

${bloque('LOGOTIPO · VERTICAL · ISOTIPO · ICONO · MONOGRAMA', `<div class="fila">
  ${pieza('taxicount-logotipo-color.svg', 230, 62, 'logotipo')}
  ${pieza('taxicount-marca-vertical-color.svg', 150, 80, 'vertical')}
  ${pieza('taxicount-isotipo-color.svg', 96, 96, 'isotipo')}
  ${pieza('taxicount-icono-app.svg', 96, 96, 'icono app')}
  ${pieza('taxicount-icono-app.svg', 52, 52, '52 px')}
  ${pieza('monograma-ct.svg', 62, 70, 'monograma')}
</div>`)}

${bloque('COLORES', `<div class="col">
  <div class="s"><i style="background:${AMBAR}"></i><b>${AMBAR} ámbar</b></div>
  <div class="s"><i style="background:${NEGRO}"></i><b>${NEGRO} negro</b></div>
  <div class="s"><i style="background:${CREMA}"></i><b>${CREMA} crema</b></div>
</div>`)}`;

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tchoja-'));
const w = path.join(tmp, 'hoja.html');
fs.writeFileSync(w, html);
const salida = path.join(HERE, 'hoja-de-marca.png');
execFileSync(EDGE, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
  `--user-data-dir=${path.join(tmp, 'u')}`, `--screenshot=${salida}`,
  '--window-size=780,940', `file:///${w.replace(/\\/g, '/')}`], { stdio: 'ignore' });
console.log(fs.existsSync(salida) ? 'hoja-de-marca.png 780x940' : 'FALLO');
