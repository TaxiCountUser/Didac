// Reune en una sola carpeta todo lo que hay que llevar a los dos registros.
//   node registro/preparar-expediente.js
// Deja el resultado en registro/EXPEDIENTE/, que NO se versiona: es material
// regenerable, igual que el ZIP del codigo fuente.
const fs = require('fs');
const path = require('path');

const HERE = __dirname;
const RAIZ = path.join(HERE, '..');
const OUT = path.join(HERE, 'EXPEDIENTE');

// Se rehace de cero en cada pasada, para que no queden restos de versiones
// anteriores que alguien pudiera acabar firmando por error.
fs.rmSync(OUT, { recursive: true, force: true });

const copiar = (origen, destino) => {
  const dst = path.join(OUT, destino);
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.copyFileSync(path.join(RAIZ, origen), dst);
  return fs.statSync(dst).size;
};
const copiarCarpeta = (origen, destino, filtro = () => true) => {
  let n = 0, bytes = 0;
  for (const f of fs.readdirSync(path.join(RAIZ, origen))) {
    if (!filtro(f)) continue;
    bytes += copiar(path.join(origen, f), path.join(destino, f));
    n++;
  }
  return [n, bytes];
};

// 1 · lo que se firma
copiar('registro/pdf/2-acuerdo-cotitularidad.pdf', '1-PARA-FIRMAR/acuerdo-cotitularidad.pdf');
copiar('registro/pdf/3-notas-del-acuerdo.pdf', '1-PARA-FIRMAR/LEER-ANTES-notas-del-acuerdo.pdf');

// 2 · marca
copiar('registro/pdf/0-datos-solicitud-marca.pdf', '2-MARCA-OEPM/datos-de-la-solicitud.pdf');
copiar('brand/taxicount-marca-mixta-color-oepm.png', '2-MARCA-OEPM/imagen-de-la-marca.png');

// 3 · propiedad intelectual
copiar('registro/pdf/1-memoria-de-la-obra.pdf', '3-PROPIEDAD-INTELECTUAL/memoria-de-la-obra.pdf');
copiar('registro/taxicount-codigo-fuente-v1.0.zip', '3-PROPIEDAD-INTELECTUAL/codigo-fuente-v1.0.zip');
const [nd] = copiarCarpeta('registro/diagramas', '3-PROPIEDAD-INTELECTUAL/diagramas', (f) => f.endsWith('.png'));
const [nc] = copiarCarpeta('registro/capturas', '3-PROPIEDAD-INTELECTUAL/capturas');

// 4 · la guia, en la raiz, que es lo primero que hay que abrir
copiar('registro/pdf/PASO-A-PASO.pdf', 'LEEME-PRIMERO-paso-a-paso.pdf');

const INDICE = `# Expediente TaxiCount — marca y propiedad intelectual

Cotitularidad al 50%: **Didac Oliveras Galvez** y **Jordi Pujadas Serra**.

Carpeta generada automáticamente con \`node registro/preparar-expediente.js\`.
No editar nada aquí dentro: se borra y se rehace en cada pasada. Los originales
están en \`registro/\`.

## Qué hay y en qué orden se usa

| Carpeta | Contenido |
|---|---|
| \`LEEME-PRIMERO-paso-a-paso.pdf\` | La guía de los dos trámites, paso por paso |
| \`1-PARA-FIRMAR/\` | El **acuerdo de cotitularidad**, lo único que se firma entre las partes y requisito previo de los dos expedientes, junto con las notas que conviene leer antes (ésas no se firman) |
| \`2-MARCA-OEPM/\` | Los datos a copiar en el formulario y la imagen de la marca que se adjunta |
| \`3-PROPIEDAD-INTELECTUAL/\` | La memoria, el código fuente depositado, los ${nd} diagramas y las ${nc} capturas |

## Antes de firmar el acuerdo

El contrato está completo: no queda ningún hueco por rellenar. Leed antes
\`LEER-ANTES-notas-del-acuerdo.pdf\`, que explica qué se ha pactado en cada punto
delicado y qué consecuencias tiene. Esas notas **no se firman**.

Firmad preferentemente con **certificado digital** (AutoFirma o Adobe Reader):
queda sellado con fecha y es verificable. Si vais a papel, dos ejemplares y cada
uno guarda el suyo.

## Antes de presentar la propiedad intelectual

Llamar antes al Registre de la Propietat Intel·lectual de Catalunya y preguntar
**en qué formato admiten el código fuente**. No todos aceptan un ZIP; es habitual
que pidan un PDF con el listado, y muchos admiten depositar solo una parte.

## Tasas

| Trámite | Importe |
|---|---|
| Marca, tres clases, telemático | 293,56 € |
| Propiedad intelectual | 13,65 € (+13,65 € si se quiere el certificado) |
`;
fs.writeFileSync(path.join(OUT, 'INDICE.md'), INDICE);

let total = 0, ficheros = 0;
(function medir(d) {
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) medir(p); else { total += fs.statSync(p).size; ficheros++; }
  }
})(OUT);

console.log(`${ficheros} archivos · ${(total / 1048576).toFixed(2)} MB en ${OUT}`);
