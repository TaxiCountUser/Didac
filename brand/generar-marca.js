// Genera el juego completo de marca a partir del monograma del titular.
//   node brand/generar-marca.js <negro|calado> <carpeta-destino>
// El monograma se lee de brand/monograma-ct.svg, asi que si se retoca alli,
// todo lo demas se regenera solo.
const fs = require('fs');
const path = require('path');

const VAR = process.argv[2];
const OUT = process.argv[3];
if (!['negro', 'calado'].includes(VAR) || !OUT) {
  console.error('uso: node generar-marca.js <negro|calado> <carpeta>'); process.exit(1);
}
fs.mkdirSync(OUT, { recursive: true });

const AMBAR = '#FFC107', AMBAR_LOGO = '#FFB300', NEGRO = '#1E1B16', CREMA = '#FEF7EC';

// --- monograma del titular
const src = fs.readFileSync(path.join(__dirname, 'monograma-ct.svg'), 'utf8');
const MD = src.match(/ d="([^"]+)"/)[1];
const [, MW, MH] = src.match(/viewBox="0 0 (\d+) (\d+)"/).map(Number);
// alto 26 en el frontal, centrado en la banda libre (carroceria 48 -> toma de aire 80.5)
const S = (26 / MH).toFixed(5);
const mono = (fill) =>
  `<g transform="translate(60,64.25) scale(${S}) translate(${-MW / 2},${-MH / 2})">` +
  `<path fill="${fill}" fill-rule="evenodd" d="${MD}"/></g>`;

// --- coche
const CARRO = `<rect x="48" y="13" width="24" height="10" rx="2"/>
        <path d="M16 48 L32 26 Q33 23 36 23 L84 23 Q87 23 88 26 L104 48 Z"/>
        <path d="M10 54 Q10 48 16 48 L104 48 Q110 48 110 54 L110 84 Q110 88 106 88 L14 88 Q10 88 10 84 Z"/>
        <path d="M14 46 L4 48 Q0 48.8 0 51 Q0 54 3 54 L14 54 Z"/>
        <path d="M106 46 L116 48 Q120 48.8 120 51 Q120 54 117 54 L106 54 Z"/>
        <path d="M16 84 L38 84 L38 92 Q38 97 32 97 L22 97 Q16 97 16 92 Z"/>
        <path d="M82 84 L104 84 L104 92 Q104 97 98 97 L88 97 Q82 97 82 92 Z"/>`;
const HUECOS = `<path d="M22 44 L36 27.5 L84 27.5 L98 44 Z"/>
        <path d="M13 58 L33 61 L33 65 L13 64 Z"/>
        <path d="M107 58 L87 61 L87 65 L107 64 Z"/>
        <rect x="32" y="80.5" width="56" height="5" rx="2.5"/>`;

// El monograma calado se resta en la mascara; el negro se pinta encima.
const calado = VAR === 'calado';
const mask = (id) => `<mask id="${id}"><rect width="120" height="120" fill="#000"/>
      <g fill="#fff">${CARRO}</g><g fill="#000">${HUECOS}</g>${calado ? mono('#000') : ''}</mask>`;
const encima = (c) => (calado ? '' : mono(c));

// --- logotipo (interletraje T-A ya corregido)
const word = (c1, c2) => `<g transform="translate(200,30)" fill="none" stroke-width="15" stroke-linecap="round" stroke-linejoin="round">
    <g stroke="${c1}">
      <path d="M0,8 H70 M35,8 V92"/>
      <path d="M76,92 L112,8 L148,92 M90,63 H134"/>
      <path d="M168,8 L232,92 M232,8 L168,92"/>
      <path d="M252,8 V92"/>
    </g>
    <g stroke="${c2}">
      <path d="M343.7,20.3 A42,42 0 1,0 343.7,79.7"/>
      <path d="M376,50 A42,42 0 1,1 460,50 A42,42 0 1,1 376,50"/>
      <path d="M480,8 V50 A42,42 0 0,0 564,50 V8"/>
      <path d="M584,92 V8 L654,92 V8"/>
      <path d="M674,8 H744 M709,8 V92"/>
    </g>
  </g>`;

const svg = (vb, w, h, title, body) =>
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${vb}" width="${w}" height="${h}">
  <title>${title}</title>
${body}
</svg>\n`;

const files = {
  'taxicount-isotipo-color.svg': svg('0 0 120 120', 120, 120, 'TaxiCount — isotipo',
    `  <defs>${mask('i')}</defs>
  <rect width="120" height="120" fill="${AMBAR}" mask="url(#i)"/>${encima(NEGRO)}`),

  'taxicount-isotipo-negro.svg': svg('0 0 120 120', 120, 120, 'TaxiCount — isotipo blanco y negro',
    // sobre carroceria negra el monograma va siempre calado, o no se veria
    `  <defs><mask id="ibn"><rect width="120" height="120" fill="#000"/>
      <g fill="#fff">${CARRO}</g><g fill="#000">${HUECOS}</g>${mono('#000')}</mask></defs>
  <rect width="120" height="120" fill="#000000" mask="url(#ibn)"/>`),

  'taxicount-marca-mixta-color.svg': svg('0 0 961 160', 961, 160, 'TaxiCount — marca mixta (color)',
    `  <defs>${mask('m')}</defs>
  <g transform="translate(0,2) scale(1.3)"><rect width="120" height="120" fill="${AMBAR}" mask="url(#m)"/>${encima(NEGRO)}</g>
${word(NEGRO, AMBAR_LOGO)}`),

  'taxicount-marca-mixta-negro.svg': svg('0 0 961 160', 961, 160, 'TaxiCount — marca mixta (blanco y negro)',
    `  <defs><mask id="mbn"><rect width="120" height="120" fill="#000"/>
      <g fill="#fff">${CARRO}</g><g fill="#000">${HUECOS}</g>${mono('#000')}</mask></defs>
  <g transform="translate(0,2) scale(1.3)"><rect width="120" height="120" fill="#000000" mask="url(#mbn)"/></g>
${word('#000000', '#000000')}`),

  'taxicount-marca-mixta-fondo-oscuro.svg': svg('0 0 961 160', 961, 160, 'TaxiCount — marca mixta para fondo oscuro',
    `  <defs>${mask('md')}</defs>
  <g transform="translate(0,2) scale(1.3)"><rect width="120" height="120" fill="${AMBAR}" mask="url(#md)"/>${encima(NEGRO)}</g>
${word(CREMA, AMBAR_LOGO)}`),

  'taxicount-marca-vertical-color.svg': svg('0 0 760 300', 760, 300, 'TaxiCount — marca mixta vertical (color)',
    `  <defs>${mask('v')}</defs>
  <g transform="translate(300,0) scale(1.3333)"><rect width="120" height="120" fill="${AMBAR}" mask="url(#v)"/>${encima(NEGRO)}</g>
  <g transform="translate(8,200)" fill="none" stroke-width="15" stroke-linecap="round" stroke-linejoin="round">
    <g stroke="${NEGRO}">
      <path d="M0,8 H70 M35,8 V92"/><path d="M76,92 L112,8 L148,92 M90,63 H134"/>
      <path d="M168,8 L232,92 M232,8 L168,92"/><path d="M252,8 V92"/>
    </g>
    <g stroke="${AMBAR_LOGO}">
      <path d="M343.7,20.3 A42,42 0 1,0 343.7,79.7"/>
      <path d="M376,50 A42,42 0 1,1 460,50 A42,42 0 1,1 376,50"/>
      <path d="M480,8 V50 A42,42 0 0,0 564,50 V8"/>
      <path d="M584,92 V8 L654,92 V8"/>
      <path d="M674,8 H744 M709,8 V92"/>
    </g>
  </g>`),

  // Icono de app: fondo ambar, carroceria crema. El monograma calado deja ver
  // el ambar del fondo; el negro se pinta encima de la carroceria.
  'taxicount-icono-app.svg': svg('0 0 120 120', 120, 120, 'TaxiCount — icono de aplicacion',
    `  <rect width="120" height="120" rx="26" fill="${AMBAR}"/>
  <g transform="translate(60,61) scale(0.9) translate(-60,-60)">
    <g fill="${CREMA}">${CARRO}</g>
    <g fill="${AMBAR}">${HUECOS}</g>
    ${mono(calado ? AMBAR : NEGRO)}
  </g>`),
};

for (const [name, body] of Object.entries(files)) fs.writeFileSync(path.join(OUT, name), body);
console.log(`variante "${VAR}": ${Object.keys(files).length} archivos en ${OUT}`);
