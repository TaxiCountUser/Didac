# Memoria descriptiva de la obra

Documento de apoyo a la solicitud de inscripción en el **Registro de la Propiedad
Intelectual** de un programa de ordenador.

Preparado el 30 de julio de 2026. Actualizado el 3 de agosto de 2026 para **cotitularidad de
los derechos de explotación al 50%**.

> ⚠️ **Requisito previo:** antes de presentar debe estar firmado el **acuerdo de
> cotitularidad** (`acuerdo-cotitularidad.md`, apartado 9 de esta memoria). Sin él, la
> declaración de titularidad compartida carece de respaldo.

---

## 1. Identificación de la obra

| Campo | Valor |
|---|---|
| Título | TaxiCount — plataforma SaaS de gestión económica de flotas de taxi |
| Clase de obra | Programa de ordenador |
| Versión que se deposita | 1.0 |
| Autor del programa | Didac Oliveras Galvez, NIF 41556654R — Calle Tapis 37, 17600 Figueres (Girona), España |
| Coautor de los textos legales incorporados | Jordi Pujadas Serra, NIF ⬜ **PENDIENTE** (ver apartado 9) |
| Titulares de los derechos de explotación | Didac Oliveras Galvez **50%** · Jordi Pujadas Serra **50%**, en virtud del acuerdo de cotitularidad que se acompaña |
| Fecha de creación | **19 de junio de 2026** (primera revisión del control de versiones, «Fase 0 completada: entorno dev validado») |
| Divulgación | **Obra divulgada.** El repositorio de código es **público** desde su creación, el 21 de junio de 2026. La primera distribución pública de la aplicación compilada que se conserva es del **27 de junio de 2026** |
| Registro donde se presenta | **Registro de la Propiedad Intelectual de Cataluña**, gestionado por la Generalitat |

## 2. Objeto y finalidad

TaxiCount es una plataforma en la nube, de arquitectura multiempresa, destinada a la
**gestión económica y administrativa de flotas de taxi y de taxistas autónomos**. Cada
empresa cliente opera de forma completamente aislada del resto.

El programa cubre el ciclo completo de explotación de una flota:

- Registro de ingresos y gastos, manual o **por voz** con transcripción automática.
- Cuadros de mando en tiempo real para el titular de la flota.
- Generación de informes fiscales en Excel y PDF, e importación desde hoja de cálculo,
  fotografía o documento PDF.
- Gestión de conductores, vehículos y asignaciones.
- Canal de mensajería entre el titular de la flota y sus conductores.
- Facturación por suscripción con periodo de prueba.
- Mecanismos de fidelización: retos con recompensa y programa de recomendación.
- Panel de administración de la plataforma, con supervisión, auditoría y observabilidad.

## 3. Lenguajes de programación y entorno

| Componente | Lenguaje y tecnología | Volumen |
|---|---|---|
| Aplicación cliente | Dart, sobre Flutter | 27.479 líneas en 86 archivos |
| Servidor de aplicación | JavaScript, sobre Node.js y Fastify | 10.153 líneas en 39 archivos |
| Base de datos | SQL (PostgreSQL), en migraciones versionadas | 7.101 líneas en 85 archivos |
| **Subtotal de código** | | **44.733 líneas en 210 archivos** |
| Automatización e infraestructura | YAML | 1.462 líneas en 17 archivos |
| Documentación técnica | Markdown | 4.613 líneas en 41 archivos |

**Total: 50.808 líneas de código, automatización y documentación**, de las cuales 44.733 son
código de programa en sentido estricto. El depósito comprende **342 archivos**.

**Sistemas operativos y plataformas de destino:** Android (distribución por archivo APK y
por Google Play) y navegador web. El servidor de aplicación se ejecuta sobre Node.js en un
proveedor de alojamiento en la nube.

## 4. Arquitectura

El sistema se compone de **tres piezas de despliegue independientes** —aplicación cliente,
servidor de aplicación y base de datos gestionada— y su rasgo arquitectónico distintivo es
la **doble ruta de datos**: el cliente no se comunica con un único servidor, sino que elige
la vía según el nivel de privilegio que requiera cada operación.

Por la **ruta A**, la aplicación consulta y escribe directamente contra la base de datos
usando el testigo de sesión del propio usuario, y es la base de datos la que impone la
autorización mediante políticas de seguridad a nivel de fila, garantizando el aislamiento
entre empresas. Por la **ruta B**, la aplicación llama al servidor de aplicación para todo
aquello que exige credenciales o privilegios que nunca pueden residir en el dispositivo del
usuario: alta de conductores, transcripción de voz, operaciones de cobro, generación de
informes y la totalidad del panel de administración.

Esta decisión reduce la superficie de exposición y evita que el servidor sea un cuello de
botella en las operaciones ordinarias.

Se acompañan dos diagramas:

- `diagramas/arquitectura.svg` (y su versión `.png`) — piezas de despliegue y ambas rutas.
- `diagramas/flujo-voz.svg` (y su versión `.png`) — recorrido completo del registro de un
  servicio dictado por voz, desde la grabación hasta la recepción en el panel del titular.

## 5. Estructura de los módulos

**Aplicación cliente** (`frontend/lib/`): dos puntos de entrada que comparten código —
`main.dart` para la aplicación de explotación que usan conductores y titulares de flota, y
`main_admin.dart` para el panel de administración de la plataforma, que se compila y
distribuye por separado. La navegación se resuelve mediante controles de acceso declarativos
que deciden la pantalla según el rol y el estado de la cuenta. La internacionalización es
propia, con un diccionario en castellano, inglés y catalán.

**Servidor de aplicación** (`backend/src/`): 98 puntos de entrada HTTP organizados en 17
módulos por dominio —facturación, análisis de la voz, notificaciones, informes, importación,
correcciones, registro de seguridad, recompensas, monitorización, retos, fraude,
recomendaciones, incidencias, suscripción, empresas, métricas y usuarios administradores.

**Base de datos** (`supabase/migrations/`): esquema versionado de 29 tablas, con
procedimientos almacenados y 53 políticas de seguridad a nivel de fila.

## 6. Descripción de la interfaz

La aplicación de explotación adopta un lenguaje visual cálido, con fondo crema y acento
ámbar, y está pensada para un uso rápido y con una sola mano dentro del vehículo: la
pantalla principal del conductor reduce la interacción a dos acciones grandes y un botón
flotante de dictado por voz. El panel de administración, dirigido a un público distinto,
emplea un tema oscuro con acentos por módulo.

Toda la interfaz está disponible en **castellano, inglés y catalán**, con selector visible
mediante bandera.

Se acompañan las siguientes capturas, obtenidas de la compilación de la versión que se
deposita:

**Del navegador** (compilación web de la versión depositada):

| Archivo | Contenido |
|---|---|
| `01-cliente-login.png` | Inicio de sesión de la aplicación cliente |
| `02-cliente-alta-empresa.png` | Alta de cuenta de titular de flota |
| `03-cliente-recuperar-password.png` | Recuperación de contraseña |
| `04-cliente-login-english.png` | Inicio de sesión en inglés |
| `05-cliente-login-catala.png` | Inicio de sesión en catalán |
| `06-admin-login-web.png` | Acceso al panel de administración (tema oscuro) |

**Del dispositivo Android** (versión 0.1.94, cuenta de demostración con datos ficticios):

| Archivo | Contenido |
|---|---|
| `07-tutorial-1-bienvenida.jpg` … `10-tutorial-4-avisos-e-incidencias.jpg` | Las cuatro diapositivas del tutorial de bienvenida |
| `11-terminos-y-privacidad.jpg` | Aceptación de términos y política de privacidad |
| `12-eleccion-de-rol.jpg` | Elección de modo de uso: flota, autónomo o conductor invitado |
| `13-onboarding-configura-tu-flota.jpg` | Configuración inicial de la flota en dos pasos |
| `14-portada-del-conductor.jpg` | Pantalla principal del conductor |
| `15-empezar-jornada.jpg` · `16-finalizar-jornada.jpg` | Apertura y cierre de jornada con lectura de kilómetros |
| `17-anadir-registro-por-voz.jpg` · `18-dictado-grabando.jpg` | Dictado por voz, en reposo y grabando con visualización de onda |
| `19-anadir-registro-manual.jpg` · `20-anadir-registro-metodo-de-pago.jpg` | Alta manual de carrera o gasto, con métodos de cobro |
| `21-mis-transacciones.jpg` · `22-selector-de-fecha.jpg` | Historial del conductor y filtro por periodo |
| `23-panel-del-jefe.jpg` | Cuadro de mando de la flota, con los importes ocultos por el modo de privacidad |
| `24-vehiculos.jpg` · `25-conductores.jpg` · `26-mensajes.jpg` | Gestión de vehículos, conductores y canal de mensajería |
| `27-soporte-tickets.jpg` | Canal de soporte |
| `28-cambiar-contrasena.jpg` | Cambio de contraseña |
| `29-novedades.jpg` | Historial de versiones dentro de la aplicación |

Las capturas corresponden a la versión ya rebautizada con la marca original: el isotipo
sustituye al pictograma de biblioteca que se usaba antes, y el nombre aparece con el corte
de color de la marca que se registra, "Taxi" en el color del tema y "Count" en ámbar.

Todas las capturas de dispositivo proceden de una **cuenta de demostración con datos
ficticios**, no de la cuenta real del autor, y ninguna muestra nombres, correos, matrículas,
kilometrajes ni importes reales. En el cuadro de mando del titular se aprovechó el modo de
privacidad de la propia aplicación, que enmascara los importes.

Se descartaron deliberadamente las capturas que mostraban datos identificativos: las de la
cuenta real del autor (nombre, correo, nombre de usuario, matrícula, modelo de vehículo y
kilometraje) y, ya en la cuenta de demostración, las pantallas de Ajustes y de Conductores,
porque exhibían un correo electrónico real, el nombre del titular y el código de acceso a la
flota.

## 7. Contenido del depósito

Archivo `taxicount-codigo-fuente-v1.0.zip` — 342 archivos, 1,16 MB comprimido.

Contiene el **código fuente original completo**: aplicación cliente, servidor de aplicación,
migraciones de base de datos, pruebas automatizadas, guiones de infraestructura y
documentación técnica.

Se ha excluido deliberadamente todo lo que **no** constituye obra del autor: bibliotecas de
terceros descargadas, artefactos de compilación y copias de seguridad de datos. El paquete
tampoco contiene credenciales ni claves: los únicos valores presentes son marcadores de
ejemplo.

## 8. Componentes de terceros

La obra se apoya en bibliotecas de código abierto ampliamente difundidas, que **no forman
parte de lo que se registra** y cuya titularidad corresponde a sus respectivos autores.

En la aplicación cliente: entre otras, el propio marco de trabajo Flutter, el cliente de la
base de datos, almacenamiento seguro, grabación de audio, gráficos, geolocalización,
selección de archivos e imágenes, notificaciones y acceso con cuenta de Google.

En el servidor: el marco web Fastify, el cliente de la base de datos, la pasarela de pagos,
la generación de hojas de cálculo y de documentos PDF, el cliente del servicio de
transcripción, la mensajería push y la instrumentación de errores.

Lo que se registra es **la obra original del autor**: el código propio, su arquitectura, la
selección y disposición de los componentes y la lógica de negocio.

## 9. Autoría

El historial de control de versiones registra **525 revisiones entre el 19 de junio y el 3 de
agosto de 2026, todas ellas con la misma dirección de correo electrónico del autor**. Una sola
de ellas figura con el nombre de su cuenta de la plataforma de alojamiento en lugar de su
nombre personal, por haberse aceptado una fusión desde el navegador; el correo es el mismo y la
persona también. **No consta ninguna revisión de terceros**, tampoco en las migraciones de base
de datos ni en la documentación legal.

**Objeto de la autoría reclamada.** El autor declara como propia la **concepción del
producto, la arquitectura del sistema, la lógica de negocio, el modelo de datos, el diseño de
la interfaz y la selección y disposición del conjunto**, así como la dirección, revisión e
integración de todo el código. En la escritura material del código se empleó **asistencia de
herramientas de inteligencia artificial contratadas por el propio autor**, bajo su dirección
y control, del mismo modo que se emplean entornos de desarrollo, generadores de código y
bibliotecas. La aportación creativa personal —qué construir, cómo estructurarlo, qué decidir
en cada disyuntiva y qué integrar— corresponde íntegramente al autor.

**Textos legales redactados en colaboración.** La documentación jurídica del proyecto se
redactó **conjuntamente con D. Jordi Pujadas Serra**, que colaboró con el autor en materia de
seguridad de la aplicación y protección de datos. Se trata por tanto de **obra en
colaboración** en cuanto a esos textos concretos, que son:

- `docs/legal/` — política de privacidad, evaluación de impacto, registro de actividades de
  tratamiento, contrato de encargo de tratamiento y procedimiento de brechas (488 líneas).
- `backend/src/server.js`, función `privacyHtml()` (líneas 84 a 133) — la política de
  privacidad que el servidor publica en `/privacy`.
- `frontend/lib/l10n/app_localizations.dart` — las 21 cadenas `legal_*` (siete textos en tres
  idiomas) que la aplicación muestra en la pantalla de aceptación de términos.

El resto de la obra —la totalidad del programa: aplicación cliente, servidor de aplicación,
modelo de datos, interfaz y automatización— es de autoría exclusiva del autor.

Conviene subrayar que estos textos legales **no son el programa de ordenador**: son
documentación jurídica exigida por la normativa de protección de datos, incorporada al
producto. Su presencia no altera la autoría del software.

**Titularidad de los derechos de explotación.** Los derechos de explotación de la obra
pertenecen a **D. Didac Oliveras Galvez y D. Jordi Pujadas Serra, al cincuenta por ciento cada
uno**, en régimen de comunidad. Así resulta del acuerdo de cotitularidad que se acompaña, por
el cual el autor cede al Sr. Pujadas una participación indivisa del 50% de la totalidad de los
derechos de explotación, y el Sr. Pujadas aporta a la titularidad común los que le
correspondían sobre su aportación a los textos legales.

**Autoría y titularidad son cosas distintas, y aquí no coinciden.** El reparto al 50% afecta
únicamente a los **derechos de explotación**, que son transmisibles. La **autoría** se declara
tal como es: el programa de ordenador es obra exclusiva de D. Didac Oliveras Galvez, y los
textos legales enumerados más arriba son obra en colaboración de ambos. Los **derechos morales**
son irrenunciables e intransmisibles y permanecen en su respectivo autor; el acuerdo no los
altera ni atribuye a ninguna de las partes la autoría de lo que no ha creado.

Las partes han pactado además el reparto de facultades de decisión sobre la obra, de modo que
el desarrollo, el mantenimiento y la publicación de nuevas versiones puede realizarlos
cualquiera de los cotitulares por sí solo, mientras que la transmisión, el gravamen y las
licencias exclusivas requieren el consentimiento de ambos.

⚠️ **Requisito previo a la presentación:** este documento —borrador en
`acuerdo-cotitularidad.md`— **debe estar firmado antes de inscribir**, y hace falta el NIF del
Sr. Pujadas. Sin ambas cosas, la declaración de titularidad compartida no tendría respaldo.
