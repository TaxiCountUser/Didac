# registro/ — expedientes de propiedad industrial e intelectual

Material preparatorio para registrar TaxiCount. **No es asesoramiento jurídico firmado**:
las solicitudes las presentan y firman los titulares.

**Ambos expedientes van en cotitularidad al 50%** entre Didac Oliveras Galvez y Jordi Pujadas
Serra, decidido el 3 de agosto de 2026.

## Contenido

| Archivo | Para qué sirve |
|---|---|
| `PASO-A-PASO.md` | La guía de presentación de los dos expedientes, paso por paso |
| `marca-oepm.md` | Expediente completo de la **marca**. Solicitantes, descripción del signo, colores, clases 9/42/35, tasas, régimen de cotitularidad y búsqueda de anterioridades |
| `memoria-obra.md` | Memoria descriptiva de la obra para el **Registro de la Propiedad Intelectual** |
| `acuerdo-cotitularidad.md` | El **acuerdo al 50%** a firmar con Jordi. Requisito previo de los dos expedientes |
| `diagramas/` | Diagrama de arquitectura y diagrama del flujo de registro por voz, en SVG y PNG |
| `capturas/` | Capturas de la interfaz obtenidas de la compilación de la versión depositada |

## Lo que bloquea la presentación

1. **El NIF y el domicilio de Jordi Pujadas Serra.** Campos obligatorios de los dos
   formularios; no se puede presentar nada sin ellos.
2. **El acuerdo de cotitularidad firmado.** Es lo que acredita el 50/50. Conviene que lo
   revise un abogado y que un asesor fiscal vea la parte del reparto de ingresos: ya no
   reparte unas páginas de documentación, reparte la propiedad del producto.

   Reparto decidido el 2026-08-09: liquidación **anual**, con **primas de trabajo** acordadas
   por escrito y deducidas antes de repartir el remanente al 50% —la prima retribuye el
   trabajo, la cuota la propiedad—. Salida por **opción cruzada**: uno notifica una valoración
   total y el otro elige entre vender su mitad o comprar la del notificante a ese precio. El
   50% **subsiste con independencia de la dedicación**; lo que se ajusta es la prima.

   La cesión es del **50% sin precio en dinero**, con causa en la aportación recíproca de
   Jordi. Y el cobro sigue **de momento en la pasarela a nombre de Didac**, con liquidación
   del 50% al otro y obligación de transparencia, hasta que se constituya la sociedad que
   asuma la facturación.
3. **Seis capturas de Android** con la marca nueva, que solo puede hacer el titular porque
   requieren sesión iniciada: `07-tutorial-1-bienvenida`, `12-eleccion-de-rol`,
   `13-onboarding-configura-tu-flota`, `14-portada-del-conductor`, `15-empezar-jornada` y
   `16-finalizar-jornada`.

⚠️ **Autoría y titularidad no son lo mismo.** El 50/50 reparte los **derechos de explotación**,
que son transmisibles. La **autoría** se declara tal como es: el programa es obra exclusiva de
Didac, y solo los textos legales incorporados son obra en colaboración de los dos. Declarar a
Jordi coautor del programa sería inexacto y, además, activaría el art. 7.2 del TRLPI, que
exigiría su firma para publicar cada actualización. La razón de estructurarlo así está en el
apartado 9 de la memoria y en la cláusula cuarta del acuerdo.

`cesion-textos-legales.md` se eliminó el 3 de agosto de 2026: respondía al reparto anterior
—Didac titular único, Jordi cediéndole los textos— y contradecía el actual. Lo sustituye
`acuerdo-cotitularidad.md`. Si hace falta consultarlo, está en el historial de Git.

El ZIP del código fuente **no se versiona** (es regenerable y pesa 1,7 MB). Para rehacerlo:

```bash
git archive --format=zip --prefix=taxicount-v1.0/ -o registro/taxicount-codigo-fuente-v1.0.zip HEAD -- . ':!registro' ':!brand'
```

Las exclusiones importan: sin ellas el paquete se lleva dentro el propio expediente y los
activos de marca, y pasa de 1,1 a 6,7 MB de material que no es código fuente.
`frontend/assets/brand/` sí entra, porque el isotipo es un recurso de la aplicación.

`git archive` incluye solo lo versionado, así que el paquete sale limpio de artefactos de
compilación, dependencias descargadas y copias de seguridad.

## Cómo se obtuvieron las capturas

Las pantallas se capturaron de la compilación web real, no de un maqueta. El procedimiento
está automatizado con un controlador CDP mínimo escrito para la ocasión
(`shots.js`, en el directorio temporal de la sesión): lanza Edge en modo headless con el
puerto de depuración abierto, emula un viewport de móvil a doble densidad, navega, pulsa por
coordenadas y guarda cada captura.

Hizo falta ese rodeo porque la app no expone rutas por URL —la navegación es por
`MaterialPageRoute`— ni árbol de accesibilidad, de modo que no se puede llegar a una pantalla
concreta con solo cambiar la dirección.

**Las pantallas interiores no están**: requieren una sesión iniciada y debe capturarlas el
titular desde su propia cuenta.

Para rehacer las que sí están:

```bash
cd frontend && flutter build web --release --no-wasm-dry-run
```

Si la compilación falla al resolver paquetes en `.dart_tool`, hay que hacer
`flutter clean && flutter pub get` antes (queda un registrante de plugins cacheado de
compilaciones anteriores).

## PDF listos para presentar

`pdf/` contiene los cuatro documentos ya maquetados en A4:

| Archivo | Para qué |
|---|---|
| `PASO-A-PASO.pdf` | La guía de presentación de los dos expedientes |
| `0-datos-solicitud-marca.pdf` | Los datos a copiar en el formulario de la OEPM |
| `1-memoria-de-la-obra.pdf` | La memoria que se adjunta al Registro de la Propiedad Intelectual |
| `2-acuerdo-cotitularidad.pdf` | El acuerdo al 50% a firmar con Jordi Pujadas Serra |

Se regeneran con `md2pdf.js`, un conversor mínimo de Markdown a HTML escrito para esto (no
hay ninguno instalado en el equipo):

```bash
node registro/md2pdf.js registro/memoria-obra.md salida.html
msedge --headless=new --no-pdf-header-footer --print-to-pdf=salida.pdf salida.html
```
