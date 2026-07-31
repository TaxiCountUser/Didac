# TaxiCount — identidad de marca

Activos de la marca TaxiCount para su registro como marca mixta en la OEPM y como parte de
la obra en el Registro de la Propiedad Intelectual. Versión definitiva: **31 de julio de 2026**.

## De qué está hecha

**El símbolo** es un coche moderno visto de frente —parabrisas panorámico, montantes muy
inclinados, retrovisores que sobresalen, faros barridos, toma de aire inferior, ruedas
asomando y módulo de taxi plano en el techo— con la **ligadura CT en la parrilla**, centrada
en la banda libre del frontal.

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

```bash
node brand/generar-marca.js            # los ocho SVG
```

Lee `monograma-ct.svg` y las dos piezas de palabra, así que retocar el dibujo y relanzar
basta para rehacerlo todo.

Los PNG salen de los SVG con Edge headless (no hay Inkscape ni ImageMagick en el equipo):

```bash
msedge --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
  --user-data-dir=<temporal> --screenshot=<salida.png> --window-size=<W>,<H> file:///<wrapper.html>
```

⚠️ Cada invocación necesita su **propio** `--user-data-dir`, o las llamadas seguidas dicen
que han escrito el archivo y no lo escriben.

## Las herramientas que hizo falta escribir

El equipo no tiene trazador, ni extractor de PDF, ni conversor de fuentes, así que están aquí:

| Script | Qué hace |
|---|---|
| `extraer-imagen-pdf.js` | Saca los mapas de bits de un PDF y los guarda como PNG |
| `vectorizar-bitmap.js` | Traza una forma bitonal: marching squares + Douglas-Peucker |
| `ttf-a-trazados.js` | Convierte texto compuesto con una TrueType en trazados SVG, leyendo la tabla `glyf` |
| `generar-marca.js` | Ensambla los ocho archivos de marca |

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
