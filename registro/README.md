# registro/ — expedientes de propiedad industrial e intelectual

Material preparatorio para registrar TaxiCount. **No es asesoramiento jurídico firmado**:
las solicitudes las presenta y firma el titular.

## Contenido

| Archivo | Para qué sirve |
|---|---|
| `marca-oepm.md` | Expediente completo de la **marca** (Bloque 1, cerrado). Datos, descripción del signo, colores, clases 9/42/35, tasas y búsqueda de anterioridades |
| `memoria-obra.md` | Memoria descriptiva de la obra para el **Registro de la Propiedad Intelectual** (Bloque 2, con apartados pendientes marcados) |
| `diagramas/` | Diagrama de arquitectura y diagrama del flujo de registro por voz, en SVG y PNG |
| `capturas/` | Capturas de la interfaz obtenidas de la compilación de la versión depositada |

El ZIP del código fuente **no se versiona** (es regenerable y pesa 1,7 MB). Para rehacerlo:

```bash
git archive --format=zip --prefix=taxicount-v1.0/ -o registro/taxicount-codigo-fuente-v1.0.zip HEAD
```

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
| `2-cesion-textos-legales.pdf` | El documento a firmar con Jordi Pujadas Serra |

Se regeneran con `md2pdf.js`, un conversor mínimo de Markdown a HTML escrito para esto (no
hay ninguno instalado en el equipo):

```bash
node registro/md2pdf.js registro/memoria-obra.md salida.html
msedge --headless=new --no-pdf-header-footer --print-to-pdf=salida.pdf salida.html
```
