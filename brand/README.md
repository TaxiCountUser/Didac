# TaxiCount — identidad de marca

Activos de la marca TaxiCount para su registro como marca mixta en la OEPM y como parte de
la obra en el Registro de la Propiedad Intelectual. Versión definitiva: **3 de agosto de 2026**.

## De qué está hecha

**El símbolo** es un coche moderno visto de frente —parabrisas panorámico, montantes muy
inclinados, retrovisores que sobresalen, faros barridos, toma de aire inferior, ruedas
asomando y módulo de taxi plano en el techo— con la **ligadura CT en la parrilla**, centrada
en la banda libre del frontal.

La ligadura de la parrilla mide **16 unidades de alto** (`MONO_PARRILLA` en el generador).
Empezó en 26 y pesaba demasiado: negro sobre ámbar es el par de máximo contraste del logo,
así que a ese tamaño el monograma tiraba más de la vista que el propio coche. A 16 es un
emblema de parrilla, el coche vuelve a leerse primero y todavía se distingue hasta ~24 px.
Por encima de ~34 ni siquiera cabe: pisa los faros y la toma de aire.

**La ligadura CT la creó el titular.** Es una C y una T fundidas en una sola forma. Entregada
como PDF y vectorizada aquí (ver más abajo).

**El nombre** se compone en tres piezas: `Taxi` en Lora Regular, la **misma ligadura haciendo
de C** de "Count", y `ount` en Lora Bold. Así el símbolo y la palabra comparten literalmente
una pieza, y el contraste de peso refuerza el corte que ya hace el color.

## Por qué nada depende de fuentes ni de iconos ajenos

El icono original de la app era el glifo `local_taxi` de **Material Design Icons**. Su
licencia Apache 2.0 permite usarlo pero **no otorga derechos de marca** (cláusula 6) ni
genera autoría propia: no era registrable.

Todo lo que hay aquí es **trazado vectorial**. El coche está dibujado a mano; la ligadura es
obra del titular; y el nombre, aunque se compuso con **Lora** —licencia SIL Open Font, que
permite expresamente su uso en logotipos—, está **convertido a trazados**, de modo que el
archivo no necesita la fuente instalada ni arrastra su licencia.

> Se descartó **Georgia** justamente por esto: es propiedad de Microsoft y usar sus contornos
> en una marca registrada es terreno tolerado, no autorizado. Lora no tiene esa duda.

## Archivos

| Archivo | Uso |
|---|---|
| `taxicount-marca-mixta-color.svg` / `.png` | **Marca mixta oficial**, horizontal |
| `taxicount-marca-mixta-color-oepm.png` | Igual, con fondo blanco — el que se sube a la OEPM |
| `taxicount-marca-mixta-negro.svg` / `.png` | Blanco y negro (prensa, grabado) |
| `taxicount-marca-mixta-fondo-oscuro.svg` / `.png` | Con "Taxi" en crema, para fondos oscuros |
| `taxicount-marca-vertical-color.svg` / `.png` | Lockup vertical |
| `taxicount-logotipo-color.svg` / `.png` | Solo la denominación |
| `taxicount-isotipo-color.svg` / `.png` | Solo el símbolo |
| `taxicount-isotipo-negro.svg` | Símbolo en negro |
| `taxicount-icono-app.svg` / `.png` | Icono de aplicación, 1024×1024: **el isotipo tal cual** sobre fondo crema, sin invertir colores |
| `monograma-ct.svg` · `monograma-ct-oepm.png` | La ligadura suelta |
| `hoja-de-marca.png` | Resumen visual de todo |

**Piezas de origen** (no se usan sueltas, alimentan al generador): `palabra-taxi-regular.svg`,
`palabra-ount-negrita.svg`, `lora-*-subconjunto.ttf`.

## Colores

| Color | Hex | Uso |
|---|---|---|
| Ámbar | `#FFC107` | Carrocería **y** "Count" — un único ámbar, nunca dos |
| Negro cálido | `#1E1B16` | "Taxi" y la ligadura de la parrilla |
| Crema | `#FEF7EC` | Carrocería en el icono de app; "Taxi" sobre fondo oscuro |

⚠️ Antes había dos ámbares (`#FFC107` en el coche y `#FFB300` en "Count") y se notaba. **El
símbolo y la palabra van siempre del mismo color.**

## Regenerar

Los tres pasos, en este orden:

```bash
node brand/generar-marca.js
```
```bash
node brand/renderizar-png.js
```
```bash
node brand/hoja-de-marca.js
```

El primero rehace los ocho SVG a partir de `monograma-ct.svg` y las dos piezas de palabra,
así que retocar el dibujo y relanzar basta para rehacerlo todo.

El segundo rasteriza **los 17 PNG de golpe**: los de `brand/`, los de la app
(`frontend/assets/brand/`, `frontend/assets/icon/`) y los de la web (favicon, apple-touch,
los cuatro de PWA). Acepta un filtro por subcadena del destino, p. ej.
`node brand/renderizar-png.js icono`. Después de tocar los iconos de app hay que rehacer los
mipmaps de Android:

```bash
cd frontend && dart run flutter_launcher_icons
```

No hay Inkscape ni ImageMagick en el equipo: se rasteriza con Edge headless.

⚠️ Cada invocación de Edge necesita su **propio** `--user-data-dir`, o las llamadas seguidas
dicen que han escrito el archivo y no lo escriben. `renderizar-png.js` ya lo hace por
construcción; si algún día se rasteriza a mano, cuidado con esto.

## Las herramientas que hizo falta escribir

El equipo no tiene trazador, ni extractor de PDF, ni conversor de fuentes, así que están aquí:

| Script | Qué hace |
|---|---|
| `extraer-imagen-pdf.js` | Saca los mapas de bits de un PDF y los guarda como PNG |
| `vectorizar-bitmap.js` | Traza una forma bitonal: marching squares + Douglas-Peucker |
| `ttf-a-trazados.js` | Convierte texto compuesto con una TrueType en trazados SVG, leyendo la tabla `glyf` |
| `generar-marca.js` | Ensambla los ocho archivos de marca |
| `renderizar-png.js` | Rasteriza los 17 PNG de marca, app y web con Edge headless |
| `hoja-de-marca.js` | Arma `hoja-de-marca.png`, el resumen visual |

⚠️ **Douglas-Peucker colapsa los contornos cerrados**: la recta entre el primer y el último
punto es degenerada y todas las distancias salen nulas. Hay que partir el bucle por el punto
más lejano al inicio y simplificar cada mitad. Resuelto en el script.

⚠️ **Windows no distingue mayúsculas en nombres de archivo.** Generando piezas del logotipo,
`seg-tb.svg` y `seg-Tb.svg` eran el mismo fichero y el segundo pisaba al primero, con el
resultado de que "Taxi" medía lo mismo que "T". Nombres inequívocos.

## Interletraje

Dos ajustes, y conviene mantenerlos si algún día se rehace el logotipo.

La **ligadura** lleva 4 unidades de separación por la izquierda respecto al avance
tipográfico, porque su caja es más estrecha que la de la C de Lora. Por la derecha va
**pegada** a "ount".

Y **"ount" se genera con −5 de interletraje**. Lora Bold abre bastante más que la Regular de
"Taxi", así que sin apretarla la segunda mitad del nombre se veía visiblemente más suelta que
la primera. Se probaron 0, −3, −5 y −7; con −7 las letras empiezan a agobiarse.

```bash
node brand/ttf-a-trazados.js <lora-bold.ttf> "ount" brand/palabra-ount-negrita.svg 100 -5
```
