# TaxiCount — Informe técnico consolidado

> **Documento vivo y único** de arquitectura del proyecto (unifica el antiguo
> `ARQUITECTURA.md`). Debe actualizarse con cada cambio relevante en el código.
> Última actualización: 2026-07-05. Ámbito: monorepo completo (frontend Flutter,
> backend Fastify, base de datos Supabase, CI/CD).

---

## 1. Resumen ejecutivo

**TaxiCount** es una plataforma **SaaS B2B multi-tenant** para la gestión económica de
flotas de taxi y taxistas autónomos. Cada empresa (*tenant*) opera de forma totalmente
aislada del resto. El producto cubre el ciclo completo: registro de ingresos/gastos
(manual o **por voz** con transcripción IA), cuadros de mando en tiempo real, informes
fiscales (Excel/PDF), gestión de conductores y vehículos, **monetización con Stripe**
(suscripción por asiento con periodo de prueba), y mecanismos de crecimiento
(gamificación con retos y programa de referidos).

El sistema está **en producción**: web en GitHub Pages, backend en Render, base de datos
en Supabase Cloud, app Android distribuida por APK/Play Store. Incluye observabilidad
propia (10 semáforos de salud), auditoría, cumplimiento legal (retención fiscal 5 años,
RGPD) y CI/CD automatizado.

**Estado de madurez:** producto en producción, funcionalmente completo, con deuda técnica
acotada y localizada (principalmente el tamaño del monolito de API y la i18n propia).
La arquitectura es sólida y está bien alineada con su stack.

| Métrica | Valor |
|---|---|
| Backend | Fastify, `server.js` ~3.500 líneas + 6 módulos · 69 rutas HTTP |
| Frontend | Flutter, ~45 pantallas, i18n propia (es/en/ca) |
| Base de datos | 65 migraciones · 29 tablas · ~28 RPCs · 53 políticas RLS |
| Idiomas de la app | Español, inglés, catalán |
| Coste operativo | ~88 €/mes |

---

## 2. Stack tecnológico

### 2.1 Frontend (cliente)
- **Lenguaje:** Dart · **Framework:** Flutter (Material Design), objetivos **web** (GitHub Pages) y **Android**.
- **Librerías principales:**
  - `supabase_flutter` — auth (JWT) + acceso a datos + realtime.
  - `http` — llamadas al backend Fastify.
  - `fl_chart` — gráficos del dashboard.
  - `record` — grabación de audio para el registro por voz.
  - `firebase_messaging` / `firebase_core` — notificaciones push (FCM).
  - `geolocator`, `image_picker`, `file_picker`, `share_plus`, `url_launcher`, `package_info_plus`.
  - `google_sign_in` — login nativo de Google en Android.
- **i18n:** sistema propio (`app_localizations.dart`, mapa `_values`) vía `context.l10n.t('key', {args})` con *fallback* a la clave.
- **Config:** 12-factor mediante `String.fromEnvironment` (`--dart-define`).

### 2.2 Backend (servidor de aplicación)
- **Lenguaje:** JavaScript (Node.js ≥18, ESM) · **Framework:** **Fastify 5**.
- **Librerías principales:**
  - `@supabase/supabase-js` — cliente con `service_role` (operaciones privilegiadas).
  - `stripe` — checkout, portal de facturación, verificación de webhooks.
  - `openai` — Whisper (transcripción) y parser LLM (compatible OpenAI/Groq).
  - `exceljs` / `pdfmake` — generación de informes.
  - `firebase-admin` — envío de push FCM.
  - `@logtail/pino` — transporte de logs a Better Stack (activo solo con `LOGTAIL_SOURCE_TOKEN`; los Log Streams nativos de Render requieren plan Professional).
  - `@sentry/node` — monitorización de errores (activada por DSN).
  - `@fastify/cors`, `@fastify/multipart`.

### 2.3 Datos, autenticación e infraestructura
- **Supabase** = Postgres 15 + **RLS** + GoTrue (JWT) + PostgREST + Kong (gateway) + Realtime.
- **CI/CD:** GitHub Actions. **Hosting:** Render (API) · GitHub Pages (web) · Supabase Cloud (DB).
- **Dev local:** Docker Compose (stack Supabase completo).

---

## 3. Arquitectura y flujo de datos

### 3.1 Visión general (monorepo, 3 piezas de despliegue independiente)

```
frontend/ (Flutter)  ──►  Supabase (PostgREST + RLS)   ◄─┐
        │                          ▲                      │  Postgres
        └──────────►  backend/ (Fastify, service_role) ──┘
                              │
                              ├─► Stripe (pagos + webhooks)
                              ├─► OpenAI/Groq (Whisper + LLM)
                              └─► Firebase (push FCM)
```

### 3.2 Decisión central: **doble ruta de datos**

El cliente **no habla con un único backend**. La elección de ruta se basa en el nivel
de privilegio necesario, y es la clave de toda la arquitectura:

- **Ruta A — Supabase directo** (`DataService` → `Supabase.instance.client`):
  la mayoría del CRUD de negocio (transacciones, dashboard, historial) y el **realtime**
  (`supabase.channel`). Va con el **JWT del usuario**; la autorización la impone la
  **RLS en Postgres** (aislamiento por `tenant_id`). El backend no interviene.
- **Ruta B — Fastify** (`DataService` → `http` con Bearer JWT):
  todo lo que requiere **privilegios o secretos** que nunca pueden estar en el cliente:
  crear conductores (`service_role`), transcripción Whisper (API key OpenAI), Stripe
  (checkout/portal/**webhook**), informes Excel/PDF y **todo el panel de admin**.

> **Racional de arquitecto:** empujar la autorización de lectura/escritura a la base de
> datos (RLS) y reservar el servidor de aplicación solo para lo privilegiado reduce la
> superficie de ataque y evita que el backend sea cuello de botella del CRUD normal. Es
> el patrón idiomático correcto para Supabase.

### 3.3 Arranque y enrutado (cliente)
`main.dart` → `Supabase.initialize()` → `runApp(TaxiCountApp)` → **`AuthGate`**.
El `AuthGate` es un **router declarativo por rol y estado**: lee el perfil (`users`) y el
estado del tenant y decide la pantalla (admin / owner / driver / solo), intercalando
*gates* (cambio de contraseña, aceptación legal, tutorial, gate de suscripción, banner de
mantenimiento). Es el único punto que conoce todas las transiciones de sesión.

### 3.4 Flujo de ejemplo — registro por voz (end-to-end)
1. El conductor graba audio (`record`).
2. `POST /api/v1/transcribe` (Fastify) → **Whisper** transcribe.
3. `parseSmart()` interpreta: parser LLM (mejor en catalán) + **parser determinista**
   (`parser.js`, precisión 55/55) con *fallback*; devuelve `{text, confidence, parsed}`.
4. Pantalla de **preview editable** → el usuario confirma.
5. El cliente **inserta la transacción por la Ruta A** (Supabase directo; la RLS valida
   `tenant_id` y suscripción activa).
6. El dashboard del owner recibe el `INSERT` por **realtime** al instante (SnackBar).

### 3.5 El puente autenticación ↔ datos
Trigger `handle_new_auth_user` sobre `auth.users`: un *owner* nuevo crea su tenant; un
*driver* con `tenant_id` en la metadata se une a la flota. Conecta GoTrue con `public.users`.

---

## 4. Módulos y componentes principales

### 4.1 Frontend (`frontend/lib/`)
| Componente | Responsabilidad |
|---|---|
| `main.dart` | Bootstrap (Supabase init, tema, `MaintenanceBanner`, `AuthGate`). |
| `auth_gate.dart` | Router por rol/estado (el "portero"). |
| `config.dart` | Configuración 12-factor (`--dart-define`). |
| `services/data_service.dart` | **Capa de acceso a datos** (doble ruta: Supabase + Fastify). |
| `services/` | `push_service`, `location_service`, `update_service`, descargas. |
| `screens/` (~45) | UI por rol: driver, owner, solo, y **panel admin** (portada, empresas, facturación, retos, referidos, seguridad, soporte, errores, config). |
| `l10n/app_localizations.dart` | i18n propia (es/en/ca). |
| `models/`, `widgets/` | DTOs (`Profile`, `TenantState`) y UI compartida. |

### 4.2 Backend (`backend/src/`)
| Módulo | Responsabilidad |
|---|---|
| `server.js` (~3.500 líneas) | Monolito modular: 69 rutas, guards (`adminGuard`, `cronOrAdmin`), hook `preHandler` que blinda todo `/admin/*`, helpers de telemetría (`markCronRun`, `markService`, `probeDb`), orquestación. |
| `billing.js` | Lógica de Stripe (`applyStripeEvent`: activar/past_due/cancelar). |
| `reports.js` | Generación de Excel (`exceljs`) y PDF (`pdfmake`). |
| `parser.js` | Parser determinista de transacciones (números, categoría, tipo, pago). |
| `llm_parser.js` | Parser LLM (OpenAI/Groq) con fusión sobre el determinista. |
| `importer.js` | Importación de Excel/CSV heredado. |
| `push.js` | Envío FCM (`sendToTokens`, con estado `attempted/ok` para el semáforo). |

### 4.3 Panel de administración (tema oscuro "N")
Portada (anillo de salud + KPIs + bandeja de trabajo + módulos en tarjetas + **12 semáforos**),
Empresas (buscador global + fichas + **purga definitiva** de empresas de baja, doble confirmación),
Facturación (MRR/ARPU/churn), Retos (submenús **Resumen** / **Sospechosos**; en Resumen:
**km recorridos/día** + evolución de completados con **selector de periodo** días/meses/años/total
+ auto-refresco 20 s), Referidos (funnel + submenú **Fraude**), **Monitorización** (Métricas en
vivo + Semáforos + Flags), **Auditoría** (log de acciones), Soporte, Errores, Config (en caliente
+ mantenimiento).

> **Reorganización (2026-07-13):** la antigua tarjeta "Seguridad" se dividió en **Monitorización**
> y **Auditoría**; las alertas de fraude (que son de referidos) pasaron a la tarjeta **Referidos**.

> **Anti-fraude de retos:** un logro con señales sospechosas (salto de km / carrera
> desmesurada) entra como `pending` y **no** cuenta como completado ni cobra recompensa
> hasta que el admin lo **acepta**; al **rechazarlo**, si ya se había premiado se revierte
> la extensión de suscripción (se descuentan los días) para que desaparezca de las
> estadísticas de completados y del ahorro. Los logros limpios siguen auto-aprobados.
>
> **Corregir km:** desde el detalle del reto, el admin puede editar o eliminar una lectura
> de cuentakilómetros mal introducida por el conductor (inicio/cierre de jornada) —
> `GET /admin/drivers/:id/odometer`, `PATCH`/`DELETE /admin/odometer/:id`, todo auditado.
> Los retos se recalculan solos en la siguiente lectura (odómetro en vivo).

### 4.4 Observabilidad — 12 semáforos de salud + panel de métricas
Alimentados por `system_config`, la bandeja `webhook_events` y sondas en vivo;
visibles en portada y en la pestaña *Semáforos* de Auditoría (`GET /admin/semaphores`):

`API` · `BD (Supabase, latencia)` · `CRONS` · `BACKUP` · `STRIPE (webhooks)` ·
`WEBHOOKS (bandeja error/dead)` · `WHISPER` · `OPENAI` · `GROQ (rate-limit)` ·
`Recursos Supabase (CPU/RAM/disco)` · `PUSH (FCM)` · `Purga de retención`.

- `markCronRun` → frescura (rojo si >48h). `markService` → último resultado (rojo solo si
  la última llamada falló, con caducidad de 24h para no quedar pegado; la inactividad no da
  falso rojo). `probeDb` → latencia en vivo.
- **Panel de Métricas** (pestaña *Métricas* de Seguridad, `GET /admin/metrics`): barras en
  vivo del **% disponible de Groq** (por cabeceras `x-ratelimit-*`, aviso <20%) y de los
  **recursos de Supabase** — CPU/RAM/disco por scrape del endpoint privilegiado (aviso >80%)
  + tamaño de la BD y conexiones vía RPC `db_resource_stats` (migración 066).

### 4.5 Base de datos (`supabase/migrations/`, 29 tablas)
- **Núcleo:** `tenants` → `users` / `vehicles` / `transactions` (+ `vehicle_licenses`, `driver_vehicles`).
- **Jornada:** `odometer_readings`, `driver_locations`, `app_usage_days`.
- **Negocio/gamificación:** `subscription_extensions`, `challenge_claims`, `monthly_savings`, `fleet_quarterly_metrics` (obsoleta).
- **Referidos:** `referrals`, `referral_codes`, `referral_shares`, `referral_milestone_rewards`, `referral_validation_queue`, `referral_fraud_alerts`.
- **Soporte (plataforma):** `incidents` (kind='app'), `incident_messages`, `error_reports`, `fraud_alerts`.
- **Chat de flota (jefe↔conductor):** `fleet_messages` (chat directo 1:1, privado del tenant; el admin no lo ve). Reemplaza las antiguas notas `incidents kind='nota'`. El conductor ve el NOMBRE real del jefe (en chat y push): `GET /fleet/boss-name` (service_role, porque el conductor no puede leer la fila del owner por RLS). Los vehículos asignados al conductor se leen en 2 consultas (ids + vehículos), no con embed anidado (el embed bajo RLS del conductor devolvía null → "sin vehículo asignado").
- **Recuperar contraseña:** en el login, "¿Has olvidado la contraseña?" envía el enlace (`resetPasswordForEmail`, mismo redirect que Google/confirmación); al abrirlo, el evento `passwordRecovery` (main.dart) abre la pantalla de nueva contraseña.
- **Mantenimiento de vehículos:** fechas en `vehicles` (itv/taximeter_itv/insurance/transport_card + revisión por km) + `maintenance_reminders_sent` (throttle de avisos). Cron diario (maintenance-reminders.yml) avisa al jefe por push en hitos 30/15/7/1 días/día/caducado y ~1000/~200/0 km.
- **Corregir alta de un vehículo (jefe):** desde la ficha puede editar matrícula, modelo y km inicial por si se equivocó al darlo de alta. El km inicial NO se cambia a secas: reescala toda la escala del odómetro (lecturas de odómetro y carreras + `last_revision_km`) por el mismo delta, así los km ya recorridos se CONSERVAN (reto de km = lectura − inicial, invariante) y el odómetro pasa a la escala corregida. RPC atómico `rebase_vehicle_initial_km` (mig. 073, SECURITY DEFINER, solo Owner).
- **Plataforma:** `system_config`, `admin_actions_log`, `cron_execution_logs`, `device_tokens`.
- **Seguridad en el motor:** 53 políticas RLS + helpers `SECURITY DEFINER`
  (`current_tenant_id`, `current_role_name`, `is_platform_admin`, `current_subscription_active`)
  y ~28 RPCs de negocio.

---

## 5. Dependencias y servicios externos

| Servicio | Uso | Integración | Vigilancia |
|---|---|---|---|
| **Supabase** | Postgres + Auth (JWT) + realtime | cliente directo (RLS) y backend (`service_role`) | semáforos **BD** (latencia) / **Recursos** (CPU/RAM/disco vía scrape + `db_resource_stats`) |
| **Stripe** | Suscripciones per-asiento (máx. 100). **Asientos PRE-PAGADOS** = cupo de conductores (`tenants.drivers_limit`): durante la prueba se añaden sin límite; al pagar solo quedan activos los asientos pagados (bloquea los más nuevos, `enforceSeatLimit`). Ajustar asientos (`/subscription/seats`) cobra la parte proporcional YA (`always_invoice`) y **pide confirmación con el importe** (GET `/subscription/seats` da periodo+precio real). Portal, **cupón activo** (system_config `active_coupon`), webhooks idempotentes (`webhook_events` + reproceso de la bandeja). **Ingresos reales cobrados** (total facturado neto + descontado con cupones) se leen EN VIVO de las facturas pagadas de Stripe: global en el dashboard (caché 60 s) y por empresa en su ficha (protección de datos: es lo que la empresa nos paga a nosotros, NO sus finanzas internas). **Ciclo de vida (owner):** un solo plan por asiento; mensual/anual es el PERIODO de facturación (no planes distintos). Cancelar a fin de periodo (`/subscription/cancel`, `cancel_at_period_end`, reactivable). **Baja de la empresa** (`/company/close`): cancela Stripe + cierre lógico (`closeTenantAccount`: `closed_at`, retención GDPR, elimina accesos), reutilizado por el cierre del admin. **Reactivar empresa** (admin, `/admin/company/:id/reactivate`, antes de purgar): quita `closed_at`, restaura nombre, regenera código de flota, da prueba ('trialing') y crea la cuenta del nuevo owner con contraseña temporal (los conductores se re-invitan) | backend (`billing.js`, `/subscription/seats`, `/subscription/cancel`, `/company/close`, `readGlobalRevenue`/`readTenantRevenue`, `/webhooks/stripe`, `retryFailedWebhooks`) | semáforos **STRIPE** (firma) / **WEBHOOKS** (bandeja) |
| **OpenAI / Groq** | Whisper (voz) + parser LLM | backend (`/transcribe`, `llm_parser.js`) | semáforos **WHISPER** / **OPENAI** / **GROQ** (rate-limit en vivo) |
| **Firebase (FCM)** | Notificaciones push | backend (`push.js`, `firebase-admin`) | semáforo **PUSH** |
| **Sentry** | Errores (solo backend; el frontend no lo lleva) | activado por `SENTRY_DSN` — verificado 2026-07-10: **aún sin configurar en prod** (`/health` → `sentry:false`); alta pendiente en T4 | — |
| **GitHub Actions** | CI/CD, crons, backup diario | workflows | semáforos **CRONS** / **BACKUP** |
| **Render** | Hosting del backend | despliegue | semáforo **API** |
| **GitHub Pages / Releases** | Web + distribución APK + auto-update | `deploy-web.yml`, `build-apk.yml` | — |

**Secretos y aislamiento:** `service_role` y las claves secretas de Stripe **nunca** están
en el código de la app; se inyectan por variables de entorno (Render) y GitHub Secrets. Los
crons externos se autentican con `x-cron-secret`.

---

## 6. Recomendaciones de mejora y refactorización

### 6.1 Prioridad alta
1. **Modularizar `server.js` (~3.500 líneas).** Extraer routers por dominio
   (`routes/admin.js`, `routes/billing.js`, `routes/transcribe.js`, `routes/referrals.js`)
   y una capa de servicios. El monolito funciona, pero el coste de cambio y el riesgo de
   regresión crecen con cada feature. Es la deuda técnica más rentable de pagar.
2. ✅ **Cobertura de tests de la lógica crítica de webhooks — RESUELTO (2026-07-08).**
   Nuevo job de CI `test-backend-integration` (ci.yml) que levanta el stack Supabase con
   docker compose y ejecuta de verdad webhook/billing_endpoints/excel/pdf. Con
   `CI_REQUIRE_STACK=1`, un stack caído es fallo, no skip.

> **Plan de transición MVP → producción (2026-07-08):** hoja de ruta de 3 meses aprobada
> (Mes 1 estabilización/observabilidad · Mes 2 Strangler-Fig de billing · Mes 3 BD/caché).
> Decisión: NO migrar a AWS por ahora (managed hasta ~100k conductores).
>
> **✅ MES 1 CERRADO (2026-07-11, 14/14 tickets en 3 días):** Supabase Pro + pooler +
> índices (061) · backups con simulacro de restauración mensual automatizado · Sentry
> con alertas · logs a Better Stack (@logtail/pino) · UptimeRobot · vigía de semáforos
> cada 15 min (detectó y ayudó a arreglar el push de FCM roto) · CI de integración
> (webhook/billing contra stack real). **Capacidad medida (load test):** ~1.000
> conductores concurrentes, ≈100 tx/s, mediana 69 ms, 0,003% error, en staging Free
> tier (suelo; prod Pro rinde más). Primer límite: la agregación del dashboard bajo
> concurrencia de paneles → su fix es el Mes 3 (agregación en backend + caché).
> Detalle: [docs/plan-produccion/mes-1-tickets.md](docs/plan-produccion/mes-1-tickets.md).
>
> **▶ MES 2 CERRADO (2026-07-13) — Strangler-Fig del billing.** Fase 1: tabla
> `webhook_events` (mig. 062) + webhook idempotente y durable. Fase 2: dominio
> extraído a `billing.js::handleStripeEvent(supabase, event, deps)` (el handler
> HTTP solo hace firma/idempotencia/ACK). M2-6: **reproceso de la bandeja** —
> `POST /admin/cron/retry-webhooks` (`drainWebhookQueue`) reintenta `error` (tope
> `WEBHOOK_MAX_ATTEMPTS=6` → `dead`), cada 15 min vía `retry-webhooks.yml`.
> M2-5/7: **procesamiento asíncrono conmutable** — feature flag `webhook_async`
> (en `system_config`, `GET/POST /admin/flags` + toggle en el panel); con el flag
> ON el webhook hace ACK inmediato (`queued`) y el cron drena `received`; si la
> bandeja no está, cae a síncrono (nunca pierde el evento). **Arranca OFF** (no
> hace falta aún). Semáforo **WEBHOOKS** vigila rotos (`error`/`dead`) y atascados
> (`received` > 10 min). M2-9: runbook de cutover + rollback sin deploy en
> [manual-m2-cutover.md](docs/plan-produccion/manual-m2-cutover.md). Siguiente:
> Mes 3 (agregación del dashboard al backend + caché).
> Detalle: [docs/plan-produccion/mes-2-tickets.md](docs/plan-produccion/mes-2-tickets.md).
>
> **▶ MES 3 EN CURSO — agregación del dashboard + caché/rollups.** Ataca el primer
> límite del load test (agregación bajo concurrencia de paneles). M3-1
> (2026-07-13): **RPC `report_summary`** (mig. 063) agrega el resumen del
> dashboard en Postgres (`SUM ... FILTER` + `GROUP BY`) en vez de traer todas las
> filas al cliente; `transactionsSummary` la usa con **fallback** a la agregación
> antigua si la RPC no está (despliegue desacoplado). INVOKER + RLS (aislamiento
> por tenant/rol) verificado contra el stack real. M3-2 (2026-07-13): **RPC
> `period_report`** (mig. 064) agrega el dinero del cierre de jornada + ventanas
> de actividad por día (para las horas); km (odómetros) y cómputo de horas siguen
> en cliente sin cambios (no se regresiona el cierre). Fallback igual. M3-5
> (2026-07-13): **re-medido con k6** (A/B rpc vs pull antiguo) — a 50k tx / 30
> paneles la RPC es 3,4× mejor en p95 (0,95 s vs 3,23 s) y mueve ~20× menos datos
> (48 MB vs 979 MB); el modo antiguo cruza la SLA de 1500 ms, la RPC no. M3-3/4
> (2026-07-13): **rollups diarios** (mig. 065, tabla `tenant_daily_rollup`
> mantenida exacta por trigger `tx_rollup_aiud` sobre `transactions`; RPCs
> `report_summary_rollup`/`period_report_rollup`) — el cliente los usa en rangos
> mes/año sin filtro, con fallback a las RPCs crudas; verificado **rollup == crudo**
> contra el stack real. **MES 3 CERRADO** — los tres meses del plan completos.
> Detalle: [docs/plan-produccion/mes-3-tickets.md](docs/plan-produccion/mes-3-tickets.md).

### 6.2 Prioridad media
3. **Reconsiderar la i18n propia.** El mapa único en `app_localizations.dart` es pragmático
   pero frágil (los apóstrofos catalanes ya han roto builds) y no escala. Migrar a
   `flutter_localizations` + ARB con generación, o al menos añadir un test que valide que
   las 3 lenguas tienen el mismo conjunto de claves.
4. **Unificar la lógica de negocio duplicada cliente/servidor** (p. ej. estados de
   suscripción y su interpretación) en una única fuente de verdad para evitar divergencias.
5. **Retirar código obsoleto residual.** Tablas/campos heredados (`fleet_quarterly_metrics`,
   `monthly_savings`) que ya no alimentan features vivas; documentar o eliminar tras backup.

### 6.3 Prioridad baja / evolutivo
6. **Programar la purga de retención** en un workflow anual (hoy es manual; su semáforo
   quedará informativo hasta entonces) y unificar el endpoint a `cronOrAdmin`.
7. **Observabilidad ampliable:** el semáforo "API" podría reflejar `/health` real en lugar
   de estar fijo a verde; añadir métricas de latencia p95 por endpoint.
8. **Índices y rendimiento:** revisar índices en las tablas de mayor volumen
   (`transactions`, `app_usage_days`) conforme crezcan los datos.
9. **Gestión de esquema:** con 65 migraciones lineales, considerar *squashing* de las
   iniciales en un baseline para acelerar el arranque limpio en dev/CI.

### 6.4 Fortalezas a preservar
- Separación de responsabilidades **por confianza** (RLS para CRUD, Fastify para lo privilegiado).
- Multi-tenancy **defendido en el motor** (RLS + `SECURITY DEFINER`) con defensa en profundidad.
- **Observabilidad real** (10 semáforos) poco habitual en un SaaS de este tamaño.
- CI/CD reproducible con versionado automático de APK y auto-update in-app.
- Cumplimiento legal integrado (retención fiscal, RGPD, aceptación de términos).

---

## Anexo A — Configuración y esquema de base de datos (detalle)

### A.1 Configuración (stack Supabase)
Definida en `docker-compose.yml` (dev) y replicada en **Supabase Cloud** (prod) vía las 65 migraciones.

| Componente | Imagen / detalle | Puerto | Función |
|---|---|---|---|
| **Postgres** | `supabase/postgres:15.1.0.147` | 5432 (127.0.0.1) | motor + RLS + RPCs |
| **GoTrue (Auth)** | `v2.151.0` | 9999 (interno) | JWT HS256, exp 3600s, autoconfirm en dev; `service_role` = rol admin |
| **PostgREST** | — | interno | API REST sobre Postgres, respeta RLS con el JWT |
| **Kong (Gateway)** | `2.8.1` | 54321 | expone `/auth/v1` y `/rest/v1`; plugins cors/key-auth/acl |
| **Realtime** | `v2.30.34` (perfil opcional) | — | publica `transactions` en `supabase_realtime` |

**Cifras del esquema:** 65 migraciones · **29 tablas** · **~28 RPCs** `public.*` · **53 políticas RLS** · 3 triggers.

**Diseño de claves foráneas:** todas las tablas de negocio llevan `tenant_id` con
`ON DELETE CASCADE` (o `SET NULL` para el admin y para `user_id`/`vehicle_id` en
`transactions`, para conservar el histórico) y `ON UPDATE CASCADE` (permite remapear el
id del perfil al id real de `auth.users`).

### A.2 Modelo de datos (29 tablas por dominio)
- **Núcleo multi-tenant:**
  - `tenants` — empresa. Base: `id, name`. Extendida: `subscription_status, trial_ends_at,
    plan_id, drivers_limit, stripe_customer_id, stripe_subscription_id, solo, join_code, closed_at`.
  - `users` — perfil (espejo de `auth.users`). `tenant_id` (FK **`ON DELETE SET NULL`** desde
    mig. 053 para que el admin sobreviva al borrado de su empresa), `email, role (owner/driver),
    name, username, is_admin, active, has_completed_onboarding, must_change_password,
    legal_accepted_version, referral_code, avatar_url`.
  - `vehicles` (`license_plate, model`, soft-delete) · `vehicle_licenses` (licencia separada,
    visible solo para el owner) · `driver_vehicles` (asignación conductor↔vehículo).
  - `transactions` — el registro económico: `tenant_id, user_id, vehicle_id, amount,
    type (income/expense), category, payment_method, description, origin, destination,
    odometer_km, client_name, hidden`.
- **Jornada y lecturas:** `odometer_readings` · `driver_locations` · `app_usage_days` (días activos para retos).
- **Facturación/gamificación:** `subscription_extensions` (días/mes gratis) · `challenge_claims` ·
  `monthly_savings` y `fleet_quarterly_metrics` (histórico/obsoleto Loop#4).
- **Referidos:** `referrals` · `referral_codes` · `referral_shares` · `referral_milestone_rewards` ·
  `referral_validation_queue` (cola de los 15 días) · `referral_fraud_alerts`.
- **Soporte y moderación:** `incidents` (kind='app') · `incident_messages` · `error_reports` · `fraud_alerts`.
- **Chat de flota:** `fleet_messages` (jefe↔conductor, chat directo privado del tenant; el admin no participa).
- **Plataforma / infra:** `system_config` (config en caliente + estado de semáforos
  `cron_last_*`/`svc_*` + **feature flags** `flag_*`, p. ej. `flag_webhook_async`) ·
  `webhook_events` (bandeja idempotente/durable de Stripe) · `tenant_daily_rollup`
  (rollups diarios del dashboard, mantenidos por trigger) · `admin_actions_log`
  (auditoría) · `cron_execution_logs` · `device_tokens` (FCM).

### A.3 Seguridad en la BD (RLS + RPCs)
- **53 políticas RLS:** aislamiento estricto por `tenant_id`; el driver solo ve sus
  `transactions`, el owner toda la flota; los drivers **no** leen `vehicles`; la escritura
  de `transactions` exige suscripción activa.
- **Helpers `SECURITY DEFINER`** (evitan la recursión en las políticas):
  `current_tenant_id()`, `current_role_name()`, `is_platform_admin()`, `current_subscription_active()`.
- **RPCs de negocio** (28): `create_owner_company`, `create_solo_company`, `join_fleet_with_code`,
  `set_solo_mode`, `accept_legal`, `mark_password_changed`, `owner_set_driver_name`,
  `set_vehicle_license`, `generate_referral_code`/`set_referral_code`/`set_my_referrer`,
  `challenge_stats`/`challenge_stats_tenant`/`challenge_km_daily` (km recorridos/día global),
  `email_for_username` (login por nombre de usuario),
  `report_summary`/`period_report` (agregación del dashboard en BD, Mes 3) +
  `report_summary_rollup`/`period_report_rollup` (sobre `tenant_daily_rollup`),
  `purge_expired_retention` (purga fiscal), `cleanup_old_incidents`.
- **Trigger clave:** `handle_new_auth_user` sobre `auth.users` — un owner nuevo crea su tenant;
  un driver con `tenant_id` en la metadata se une a la flota. Es el puente entre la
  autenticación (GoTrue) y el modelo de datos (`public.users`).

---

## 7. Conclusión

TaxiCount es un producto **en producción, funcionalmente completo y con una arquitectura
coherente** con su stack. La decisión Supabase-RLS + Fastify-privilegiado es acertada y
sostiene bien el multi-tenancy y la seguridad. El principal frente de trabajo a medio plazo
es **modularizar el monolito de la API** y **reforzar la cobertura de tests de los flujos de
pago** antes de que el crecimiento del producto encarezca los cambios. El resto de
recomendaciones son evolutivas y no bloqueantes.
