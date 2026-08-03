// Rasteriza los SVG de marca a todos los PNG que usan la app, la web y el
// expediente de la OEPM.
//   node brand/renderizar-png.js            (todo)
//   node brand/renderizar-png.js icono      (solo los destinos que casen)
//
// No hay Inkscape ni ImageMagick en el equipo: se usa Edge en modo headless.
// OJO: cada invocacion necesita su PROPIO --user-data-dir, o las llamadas
// seguidas dicen que han escrito el archivo y no lo escriben.
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');

const HERE = __dirname;
const RAIZ = path.join(HERE, '..');
const CREMA = '#FEF7EC';

const EDGE = [
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
].find((p) => fs.existsSync(p));
if (!EDGE) { console.error('No encuentro msedge.exe'); process.exit(1); }

// El isotipo recortado a la caja del coche: 120 de ancho por 88 de alto, que es
// la proporcion con la que se colocó en las pantallas de la app.
const CAJA_COCHE = '0 10 120 88';
// Zona segura del icono adaptativo de Android: el sistema recorta hasta un 33%.
const SEGURA = 'translate(60,60) scale(0.63) translate(-60,-60)';

const D = [
  // marca — los que van al expediente y a la carpeta de activos
  ['brand/taxicount-isotipo-color.png',            'taxicount-isotipo-color.svg',     1024, 1024],
  ['brand/taxicount-icono-app.png',                'taxicount-icono-app.svg',         1024, 1024],
  ['brand/taxicount-marca-mixta-color.png',        'taxicount-marca-mixta-color.svg', 1774, 350],
  ['brand/taxicount-marca-mixta-color-oepm.png',   'taxicount-marca-mixta-color.svg', 1774, 350, { fondo: '#FFFFFF' }],
  ['brand/taxicount-marca-mixta-negro.png',        'taxicount-marca-mixta-negro.svg', 1774, 350],
  ['brand/taxicount-marca-mixta-fondo-oscuro.png', 'taxicount-marca-mixta-fondo-oscuro.svg', 1774, 350],
  ['brand/taxicount-marca-vertical-color.png',     'taxicount-marca-vertical-color.svg', 1354, 720],
  ['brand/taxicount-logotipo-color.png',           'taxicount-logotipo-color.svg',    1354, 366],

  // app Flutter
  ['frontend/assets/brand/isotipo.png',   'taxicount-isotipo-color.svg', 1024, 751,  { vb: CAJA_COCHE }],
  ['frontend/assets/icon/app_icon.png',   'taxicount-icono-app.svg',     1024, 1024],
  ['frontend/assets/icon/app_icon_fg.png','taxicount-isotipo-color.svg', 1024, 1024, { envoltorio: SEGURA }],

  // web (favicon, PWA). El maskable va a sangre: fondo crema completo y el
  // coche dentro de la zona segura, sin esquinas redondeadas propias.
  ['frontend/web/favicon.png',                  'taxicount-icono-app.svg', 32, 32],
  ['frontend/web/apple-touch-icon.png',         'taxicount-icono-app.svg', 180, 180],
  ['frontend/web/icons/Icon-192.png',           'taxicount-icono-app.svg', 192, 192],
  ['frontend/web/icons/Icon-512.png',           'taxicount-icono-app.svg', 512, 512],
  ['frontend/web/icons/Icon-maskable-192.png',  'taxicount-isotipo-color.svg', 192, 192, { envoltorio: SEGURA, sangre: CREMA }],
  ['frontend/web/icons/Icon-maskable-512.png',  'taxicount-isotipo-color.svg', 512, 512, { envoltorio: SEGURA, sangre: CREMA }],
];

const filtro = process.argv[2];
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tcpng-'));
let n = 0;

for (const [destino, fuente, W, H, op = {}] of D) {
  if (filtro && !destino.includes(filtro)) continue;
  const src = fs.readFileSync(path.join(HERE, fuente), 'utf8');
  const vb = op.vb || src.match(/viewBox="([^"]+)"/)[1];
  let cuerpo = src.replace(/^[\s\S]*?<svg[^>]*>/, '').replace(/<\/svg>\s*$/, '')
                  .replace(/<title>[\s\S]*?<\/title>/, '');
  if (op.sangre) cuerpo = `<rect x="-1000" y="-1000" width="3000" height="3000" fill="${op.sangre}"/>${cuerpo}`;
  if (op.envoltorio) cuerpo = `<g transform="${op.envoltorio}">${cuerpo}</g>`;

  const html = `<style>html,body{margin:0;padding:0;background:${op.fondo || 'transparent'}}
svg{display:block}</style>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="${vb}" width="${W}" height="${H}">${cuerpo}</svg>`;
  const wrapper = path.join(tmp, `w${n}.html`);
  fs.writeFileSync(wrapper, html);

  const salida = path.join(RAIZ, destino);
  fs.mkdirSync(path.dirname(salida), { recursive: true });
  execFileSync(EDGE, [
    '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
    '--default-background-color=00000000',
    `--user-data-dir=${path.join(tmp, `u${n}`)}`,   // uno distinto por llamada, ver arriba
    `--screenshot=${salida}`,
    `--window-size=${W},${H}`,
    `file:///${wrapper.replace(/\\/g, '/')}`,
  ], { stdio: 'ignore' });

  if (!fs.existsSync(salida)) { console.error(`FALLO ${destino}`); process.exit(1); }
  console.log(`${W}x${H}  ${destino}`);
  n++;
}
console.log(`${n} PNG`);
