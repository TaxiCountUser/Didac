// Genera el juego completo de marca TaxiCount.
//   node brand/generar-marca.js [carpeta-destino]   (por defecto: brand/)
//
// Piezas de origen, todas trazados vectoriales sin dependencia de fuentes:
//   monograma-ct.svg         ligadura CT creada por el titular
//   palabra-taxi-regular.svg "Taxi" en Lora Regular, vectorizado
//   palabra-ount-negrita.svg "ount" en Lora Bold, vectorizado
//
// El nombre se compone "Taxi" + monograma (haciendo de C) + "ount".
const fs = require('fs');
const path = require('path');

const HERE = __dirname;
const OUT = process.argv[2] || HERE;
fs.mkdirSync(OUT, { recursive: true });

const AMBAR = '#FFC107';   // unico ambar: coche y "Count" comparten color
const NEGRO = '#1E1B16';
const CREMA = '#FEF7EC';

const d = (f) => fs.readFileSync(path.join(HERE, f), 'utf8').match(/ d="([^"]+)"/)[1];
const w = (f) => +fs.readFileSync(path.join(HERE, f), 'utf8').match(/viewBox="0 -144 (\d+)/)[1];

const MONO = d('monograma-ct.svg');
const TAXI = d('palabra-taxi-regular.svg'), TAXI_W = w('palabra-taxi-regular.svg');
const OUNT = d('palabra-ount-negrita.svg'), OUNT_W = w('palabra-ount-negrita.svg');

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

// monograma en la parrilla: alto 26, centrado en la banda libre del frontal
const monoCoche = (fill) =>
  `<g transform="translate(60,64.25) scale(0.04235) translate(-270.5,-307)">` +
  `<path fill="${fill}" fill-rule="evenodd" d="${MONO}"/></g>`;

let uid = 0;
const isotipo = (carroceria, monoFill, calado) => {
  uid++;
  return `<defs><mask id="m${uid}"><rect width="120" height="120" fill="#000"/>
      <g fill="#fff">${CARRO}</g><g fill="#000">${HUECOS}</g>${calado ? monoCoche('#000') : ''}</mask></defs>
  <rect width="120" height="120" fill="${carroceria}" mask="url(#m${uid})"/>${calado ? '' : monoCoche(monoFill)}`;
};

// monograma haciendo de C dentro de la palabra: alto de mayuscula 100
const MONO_W = Math.round(541 * (100 / 614));
const monoLetra = (fill) =>
  `<g transform="translate(0,-97) scale(0.16287)"><path fill="${fill}" fill-rule="evenodd" d="${MONO}"/></g>`;

// linea base en y=0
const palabra = (colTaxi, colCount) =>
  `<path fill="${colTaxi}" d="${TAXI}"/>` +
  `<g transform="translate(${TAXI_W + 4},0)">${monoLetra(colCount)}</g>` +
  `<g transform="translate(${TAXI_W + MONO_W + 14},0)"><path fill="${colCount}" d="${OUNT}"/></g>`;
const PALABRA_W = TAXI_W + MONO_W + 14 + OUNT_W;

const doc = (vb, W, H, title, body) =>
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${vb}" width="${W}" height="${H}">
  <title>${title}</title>
${body}
</svg>\n`;

const LOCK_W = Math.round(200 + PALABRA_W + 10);
const mixta = (title, carroceria, monoFill, calado, colTaxi, colCount) =>
  doc(`0 0 ${LOCK_W} 175`, LOCK_W, 175, title,
    `  <g transform="translate(0,2) scale(1.3)">${isotipo(carroceria, monoFill, calado)}</g>
  <g transform="translate(200,130)">${palabra(colTaxi, colCount)}</g>`);

const files = {
  'taxicount-isotipo-color.svg': doc('0 0 120 120', 120, 120, 'TaxiCount — isotipo',
    `  ${isotipo(AMBAR, NEGRO, false)}`),

  // sobre carroceria negra el monograma va calado, o no se veria
  'taxicount-isotipo-negro.svg': doc('0 0 120 120', 120, 120, 'TaxiCount — isotipo blanco y negro',
    `  ${isotipo('#000000', null, true)}`),

  'taxicount-logotipo-color.svg': doc(`0 -144 ${PALABRA_W} 183`, PALABRA_W, 183,
    'TaxiCount — logotipo', `  ${palabra(NEGRO, AMBAR)}`),

  'taxicount-marca-mixta-color.svg':
    mixta('TaxiCount — marca mixta (color)', AMBAR, NEGRO, false, NEGRO, AMBAR),

  'taxicount-marca-mixta-negro.svg':
    mixta('TaxiCount — marca mixta (blanco y negro)', '#000000', null, true, '#000000', '#000000'),

  'taxicount-marca-mixta-fondo-oscuro.svg':
    mixta('TaxiCount — marca mixta para fondo oscuro', AMBAR, NEGRO, false, CREMA, AMBAR),

  // En vertical el coche debe pesar mas: si va al tamaño del horizontal se
  // queda pequeño frente a los 700 de ancho de la palabra.
  'taxicount-marca-vertical-color.svg': doc(
    `0 0 ${PALABRA_W} 360`, PALABRA_W, 360, 'TaxiCount — marca mixta vertical (color)',
    `  <g transform="translate(${Math.round((PALABRA_W - 234) / 2)},0) scale(1.95)">${isotipo(AMBAR, NEGRO, false)}</g>
  <g transform="translate(0,340)">${palabra(NEGRO, AMBAR)}</g>`),

  // El icono de app es el isotipo tal cual, sobre fondo crema: mismo coche
  // ambar y mismo monograma negro, sin invertir colores.
  'taxicount-icono-app.svg': doc('0 0 120 120', 120, 120, 'TaxiCount — icono de aplicacion',
    `  <rect width="120" height="120" rx="26" fill="${CREMA}"/>
  <g transform="translate(60,61) scale(0.88) translate(-60,-60)">${isotipo(AMBAR, NEGRO, false)}</g>`),
};

for (const [name, body] of Object.entries(files)) fs.writeFileSync(path.join(OUT, name), body);
console.log(`${Object.keys(files).length} archivos en ${OUT}`);
console.log(`logotipo ${PALABRA_W}x183 · marca mixta ${LOCK_W}x175`);
