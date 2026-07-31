# TaxiCount — identidad de marca

Activos originales de la marca TaxiCount, creados el **30 de julio de 2026** para su
registro como marca mixta en la OEPM y como parte de la obra en el Registro de la
Propiedad Intelectual.

## Por qué existe esta carpeta

El icono anterior (`frontend/assets/icon/app_icon.png`) era el glifo `local_taxi` de
**Material Design Icons** (Apache 2.0). Esa licencia permite usarlo, pero **no otorga
derechos de marca** (cláusula 6) y no genera autoría propia, así que no es registrable.
Todo lo que hay en esta carpeta es **dibujo vectorial original**: formas geométricas
construidas a mano en SVG, sin fuentes tipográficas de terceros y sin obra derivada de
ninguna biblioteca de iconos. Las letras del logotipo son trazos dibujados, no texto
compuesto con una fuente, por lo que el archivo no depende de ninguna licencia externa.

## Archivos

| Archivo | Uso |
|---|---|
| `taxicount-marca-mixta-color.svg` / `.png` | **Marca mixta oficial** (isotipo + logotipo), horizontal |
| `taxicount-marca-mixta-color-oepm.png` | Igual, con fondo blanco sólido — el que se sube a la OEPM |
| `taxicount-marca-mixta-negro.svg` / `.png` | Versión en blanco y negro (prensa, fax, grabado) |
| `taxicount-marca-vertical-color.svg` / `.png` | Lockup vertical, para formatos cuadrados |
| `taxicount-logotipo-color.svg` / `.png` | Solo la denominación |
| `taxicount-isotipo-color.svg` / `.png` | Solo el símbolo, sin fondo |
| `taxicount-isotipo-negro.svg` | Símbolo en negro |
| `taxicount-icono-app.svg` / `.png` | Icono de aplicación (badge ámbar, 1024×1024) |

Los PNG con fondo transparente se generan desde los SVG; el de la OEPM lleva fondo blanco
porque la representación oficial no debe depender del color del soporte.

## Concepto

Un **coche moderno visto de frente**, en el lenguaje de las ilustraciones de automoción
actuales: parabrisas panorámico que llega casi hasta los retrovisores, montantes muy
inclinados, retrovisores que sobresalen del hombro, faros barridos hacia dentro, toma de
aire inferior, ruedas asomando bajo la carrocería y módulo de taxi plano en el techo. Nada
del taxi cuadrado de siempre. En la parrilla central va el **monograma TC**: la T en negro
cálido y la C calada,
de modo que la C toma el color de lo que haya detrás (ámbar en el icono de aplicación, que
es el color con el que "COUNT" aparece en el logotipo).

El monograma es lo que hace la marca defendible: un taxi con parrilla es genérico, un taxi
con las iniciales en la parrilla es propio, y además refuerza el elemento denominativo.

En el logotipo, "TAXI" va en negro cálido y "COUNT" en ámbar, para que la lectura en dos
partes del nombre se mantenga aunque esté todo en mayúsculas.

En la versión en blanco y negro la T también va calada, porque sobre carrocería negra un
trazo negro no se vería.

## Colores

| Color | Hex | Uso |
|---|---|---|
| Ámbar TaxiCount | `#FFC107` | Isotipo, icono de app |
| Ámbar logotipo | `#FFB300` | "COUNT" en el logotipo (algo más profundo, para contraste sobre blanco) |
| Negro cálido | `#1E1B16` | "TAXI" en el logotipo, T del monograma |
| Crema | `#FEF7EC` | Carrocería dentro del icono de app |

## Construcción tipográfica

Sans geométrica monolineal dibujada a medida: altura de mayúscula 100 unidades, grosor de
trazo 15, terminaciones y uniones redondeadas, letras redondas (C, O, U) sobre círculo
perfecto de radio 42. Interletraje de 20 unidades entre cajas de avance.

## Regenerar los PNG

Los PNG salen de los SVG con Edge en modo headless (no hay Inkscape ni ImageMagick en el
equipo). Un envoltorio HTML fija el tamaño y se captura la página:

```bash
msedge --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
  --user-data-dir=<temporal> --screenshot=<salida.png> --window-size=<W>,<H> file:///<wrapper.html>
```

Ojo: cada invocación necesita su propio `--user-data-dir`, o las llamadas seguidas dicen
que han escrito el archivo y no lo escriben.

## Fondos oscuros

`taxicount-marca-mixta-fondo-oscuro.svg` / `.png` — idéntica a la marca mixta pero con
"TAXI" en crema. La versión normal lleva "TAXI" en negro cálido y **desaparece** sobre
fondos oscuros (se detectó montando `hoja-de-marca.png`). La T del monograma sigue en
negro en las dos versiones, porque va sobre la carrocería ámbar.

`hoja-de-marca.png` es la hoja resumen de toda la identidad: sirve para ver todos los
activos de un vistazo sin abrir archivo por archivo.

## Interletraje

El par **T-A** de "TAXI" lleva un ajuste de **−14 unidades**: el hueco bajo el brazo de la T
deja aire de más y sin corregirlo la A se ve descolgada. Se probaron −8, −14 y −20; con −20
las dos letras se agobian. Si algún día se rehace el logotipo, ese ajuste hay que mantenerlo.

## Monograma CT (pendiente de cerrar)

`monograma-ct.svg` — ligadura de C y T **creada por el titular**, entregada como PDF y
vectorizada aquí. Sustituirá al monograma "TC" geométrico de la parrilla cuando se cierren
forma y color.

El PDF de origen **no era vectorial**: contenía dos mapas de bits de 3500×3500, uno con el
color y otro con la máscara de transparencia. Se extrajo la máscara —blanco puro sobre
negro, el caso ideal— y se trazó: contornos por *marching squares*, simplificación de
Douglas-Peucker y salida con regla de relleno par-impar para que la contraforma sea hueco
real. Resultado: 82 puntos, 1 KB, sin dependencia de fuentes ni de programas.

```bash
node brand/extraer-imagen-pdf.js <origen.pdf> <salida>   # saca los bitmaps del PDF
node brand/vectorizar-bitmap.js <origen.pdf> 1 salida.svg 1.2   # traza la banda 1
```

⚠️ Douglas-Peucker colapsa los contornos cerrados: la recta entre el primer y el último
punto es degenerada y todas las distancias salen nulas. Hay que partir el bucle por el punto
más lejano al inicio y simplificar cada mitad. Está resuelto en el script.

**Decisiones pendientes:** grado de encaje ya fijado por el original; falta elegir el color
del monograma. Descartados los ámbares (sin contraste sobre la carrocería); candidatos
vivos: negro cálido `#1E1B16`, chocolate `#3E2F14` y calado.
