# TaxiCount

Monorepo de TaxiCount — app de gestión para taxistas autónomos.
**Fase 0:** entorno de desarrollo local (Docker + Supabase + backend Fastify + Flutter).

## Arquitectura

```
TaxiCount/
├── backend/            # Node.js + Fastify (API)
├── frontend/           # Flutter (web / iOS / Android)
├── supabase/           # Postgres + GoTrue + PostgREST + Kong (local)
│   ├── migrations/     # 001_initial_schema.sql (tablas + RLS)
│   ├── seed.sql        # datos de prueba
│   ├── kong/kong.yml   # gateway declarativo
│   └── scripts/        # apply.sh (aplica migraciones + seed)
├── smoke-test/         # test E2E (auth + RLS multi-tenant)
├── docker-compose.yml  # orquestación local
├── .github/workflows/  # CI (lint/test backend y flutter)
└── .env.example
```

## Servicios (docker compose)

| Servicio  | Imagen                  | Puerto host | Descripción                       |
| --------- | ----------------------- | ----------- | --------------------------------- |
| `db`      | supabase/postgres       | 5432        | Postgres con roles/auth de Supabase |
| `auth`    | supabase/gotrue         | (interno)   | Autenticación (JWT)               |
| `rest`    | postgrest/postgrest     | (interno)   | API REST sobre Postgres           |
| `kong`    | kong:2.8                | 54321       | Gateway: `/auth/v1`, `/rest/v1`   |
| `db-init` | supabase/postgres       | —           | Aplica migraciones + seed (one-shot) |
| `backend` | build ./backend         | 3000        | Fastify (`/health`, `/api/v1/transcribe`) |

## Requisitos previos

⚠️ **Esta máquina aún NO tiene Docker, Node ni Flutter.** Consulta
[INSTALL.md](INSTALL.md) para instalarlos antes de levantar el entorno.

## Arranque rápido

```powershell
copy .env.example .env
docker compose up -d --build
docker compose ps          # esperar a "healthy"

cd smoke-test
npm install
node test.js               # -> ✅ SMOKE TEST OK
```

Reset limpio: `docker compose down -v`

## Modelo de datos y RLS

- `tenants`, `users` (rol `owner`/`driver`), `vehicles`, `transactions`.
- **RLS:**
  - `users`: cada uno ve su fila; el `owner` ve todas las de su tenant.
  - `transactions`: el `driver` ve solo las suyas; el `owner` ve todas las de su tenant.
  - Aislamiento estricto por `tenant_id` (un tenant nunca ve datos de otro).
- Las políticas usan helpers `SECURITY DEFINER`
  (`current_tenant_id()`, `current_role_name()`) para evitar recursión.

## Autenticación y seed

Los perfiles (`public.users`) se siembran con `seed.sql`. Los usuarios de
**autenticación** (`auth.users`) los crea el smoke test con la Admin API y
re-mapea el id del perfil al id real de auth (los FK usan `ON UPDATE CASCADE`).
Credenciales de prueba:

- `owner@test.com` / `Owner12345!`
- `driver@test.com` / `Driver12345!`

## Backend

```powershell
cd backend
npm install
npm start     # http://localhost:3000/health
npm test      # tests con fastify.inject
```

## Frontend (Flutter)

```powershell
cd frontend
flutter pub get
flutter run -d chrome
```

## CI

`.github/workflows/ci.yml` corre en push/PR a `main`: `lint-backend`,
`test-backend`, `lint-flutter`, `test-flutter`. El smoke test completo (requiere
Docker) no se ejecuta en CI.

## Estado de la Fase 0

✅ **VALIDADA** (2026-06-19). El `DevEnvironmentBootLoop` se ejecutó con éxito:
arranque limpio (`docker compose down -v` → `up -d --build`), todos los
servicios *healthy* y **smoke test E2E con exit 0** (auth + RLS multi-tenant +
aislamiento entre tenants). Reproducible desde cero sin intervención manual.

El recorrido de incidencias resueltas durante el bootstrap está documentado en
[error-report-fase0.md](error-report-fase0.md).

## Estado de la Fase 1

✅ **COMPLETADA** (2026-06-19). Autenticación real, jerarquía Owner/Driver y
paneles de gestión.

Funcionalidades:
- **Auth real** (`supabase_flutter`): login y registro de Owners.
- **Tenant automático**: trigger `handle_new_auth_user` en `auth.users`
  ([002_tenant_trigger.sql](supabase/migrations/002_tenant_trigger.sql)) — un
  Owner nuevo crea su tenant; un driver (con `tenant_id` en metadata) se une al
  del Owner.
- **Panel de vehículos** (Owner): listar / añadir / eliminar.
- **Panel de conductores** (Owner): invitar driver vía backend Fastify
  `POST /api/v1/drivers` (usa `service_role`; alternativa Edge en
  [supabase/functions/create-driver](supabase/functions/create-driver/index.ts)).
- **Vista de driver**: pantalla de bienvenida limitada (sin vehículos/drivers).
- **Onboarding** del Owner (`has_completed_onboarding`).
- **RLS reforzada** ([003_rls_refinement.sql](supabase/migrations/003_rls_refinement.sql)):
  los drivers NO leen vehículos; aislamiento estricto por tenant.

### Pruebas de la Fase 1

```powershell
# Widget tests (sin backend)
flutter test test/

# Test de integración de seguridad (requiere el stack docker arriba).
# Es Dart puro -> se corre en la VM (headless, sin navegador):
dart test integration_test/phase1_security_test.dart
```

> Nota: `flutter test integration_test/` exige un dispositivo (Windows desktop o
> chromedriver). Como el test es Dart puro (cliente Supabase, sin widgets), se
> ejecuta headless con `dart test`. Cubre: registro de Owner (+tenant), creación
> de vehículo, invitación de driver, driver sin acceso a vehículos (RLS), y
> aislamiento entre tenants.

> La Fase 1 endurece la RLS de `transactions` (sin inserción de cliente hasta la
> Fase 2), por lo que el smoke test de la Fase 0 (que insertaba transacciones
> como driver) queda **superado** intencionadamente por este diseño.

## Estado de la Fase 2

✅ **COMPLETADA** (2026-06-19). Entrada de transacciones manual y por voz.

- **Entrada manual** (`TransactionInputScreen`): importe grande, chips de
  categoría, toggles tipo (ingreso/gasto) y método de pago, descripción. FAB
  "Registrar" en la home del driver.
- **Entrada por voz** (`VoiceInputScreen`): graba con `record` → backend
  transcribe (Whisper) → `TransactionPreviewScreen` editable → confirmar.
- **Backend** `POST /api/v1/transcribe` ([server.js](backend/src/server.js)):
  exige JWT de Supabase, acepta audio multipart o `storagePath`, transcribe con
  OpenAI Whisper, **parsea** y devuelve `{ text, confidence, parsed }`.
  - **Caché** de transcripciones por usuario, **límite diario** (429 al superar
    `TRANSCRIBE_DAILY_LIMIT`, def. 150), **timeout** 15 s + 1 reintento.
  - Hook de desarrollo `ALLOW_MOCK_TRANSCRIBE=true` → permite `mock_text` para
    probar sin llamar a OpenAI.
- **Parser determinista** ([parser.js](backend/src/parser.js)): números (dígitos
  y palabras, decimales "X con Y"), categoría, tipo y método de pago. Sin IA.
- **RLS Fase 2** ([004_transactions_input.sql](supabase/migrations/004_transactions_input.sql)):
  re-habilita el insert de `transactions` para el propio usuario.

### Pruebas de la Fase 2

```powershell
# Parser semántico (precisión >=95%)
cd backend; node tests/run_parser_tests.js     # -> 55/55 = 100%

# Integración de voz (stack arriba; Whisper mockeado, headless)
cd frontend; dart test integration_test/voice_input_test.dart
```

**Precisión del parser: 55/55 = 100%** (suite en
[parser_cases.json](backend/tests/parser_cases.json)).

## Estado de la Fase 3

✅ **COMPLETADA** (2026-06-20). Dashboards y sincronización en tiempo real.

- **Historial del Driver** ([driver_transactions_screen.dart](frontend/lib/screens/driver_transactions_screen.dart)):
  lista paginada (scroll infinito, 20 por página vía `.range()`), selector de
  mes/año y navegación al detalle. RLS: el driver solo ve las suyas.
- **Dashboard del Owner** ([owner_dashboard_screen.dart](frontend/lib/screens/owner_dashboard_screen.dart)):
  KPIs (ingresos / gastos / balance), gráfico de gastos por categoría con
  `fl_chart`, y lista de transacciones de toda la flota.
- **Filtros combinables**: periodo (Hoy / Semana / Mes / Personalizado),
  conductor y vehículo. Afectan a KPIs y lista a la vez.
- **Tiempo real**: el dashboard se suscribe con `supabase.channel()`
  (`tenant_id=eq.<tenant>`); un `INSERT` se antepone a la lista, actualiza los
  KPIs y muestra un `SnackBar` «Nuevo registro de [conductor]». Se cancela en
  `dispose`.
- **Detalle / edición / borrado** ([transaction_detail_screen.dart](frontend/lib/screens/transaction_detail_screen.dart)):
  el Owner edita/elimina cualquiera de su tenant; el Driver solo las suyas
  (verificado por RLS; política `DELETE` añadida en
  [005_indexes.sql](supabase/migrations/005_indexes.sql)).
- **Índices** ([005_indexes.sql](supabase/migrations/005_indexes.sql)):
  `(tenant_id, created_at)`, `(user_id, created_at)` y `created_at` para las
  consultas frecuentes.

### Realtime en local (opcional)

El stack base es un subconjunto de Supabase y **no** incluía el servidor de
Realtime. Se añade como servicio **opcional** (perfil `realtime`):

```powershell
docker compose --profile realtime up -d   # levanta también el WebSocket
```

La app funciona sin él (sin sync en vivo); con él, los `INSERT` llegan por
WebSocket. La migración 005 crea los esquemas `_realtime` y `realtime` y publica
`transactions` en `supabase_realtime`. El truco de enrutado (alias
`realtime-dev.realtime` para que Kong reenvíe `Host` con el `external_id` del
tenant) está documentado en el `docker-compose.yml`.

### Pruebas de la Fase 3

```powershell
# Dashboard: KPIs, filtros, RLS, paginación y realtime (stack arriba).
cd frontend; dart test integration_test/dashboard_test.dart
```

El test de WebSocket se **omite automáticamente** si el servidor de Realtime no
está levantado; con `--profile realtime` arriba, verifica la entrega en vivo en
< 2 s. El resto (KPIs, filtro por conductor, aislamiento RLS del Driver,
paginación) corre siempre contra el stack base.

> Ejecuta la suite de integración en **serie** (`dart test --concurrency=1
> integration_test/`): el test de WebSocket es sensible al tiempo (ventana de
> 2 s) y puede dar falsos negativos si varios ficheros corren en paralelo.

## Estado de la Fase 4

✅ **COMPLETADA** (2026-06-20). Monetización con Stripe (suscripciones).

- **Planes** (Price IDs por entorno, modo test): Starter (≤2 conductores),
  Pro (≤10), Business (ilimitado). Ver `.env.example` y `backend/.env.example`.
- **Pantalla de suscripción** ([subscription_screen.dart](frontend/lib/screens/subscription_screen.dart)):
  plan actual (nombre, límite, estado), elegir/cambiar plan y **portal de
  facturación**. Abre las URLs de Stripe con `url_launcher`. Nueva pestaña
  "Suscripción" en la home del Owner.
- **Checkout** ([server.js](backend/src/server.js)): `POST /api/v1/create-checkout-session`
  (modo `subscription`, retorno `taxicount://subscription-success|cancel`,
  metadata con `tenant_id`/`plan_id`/`drivers_limit`).
- **Webhook** `POST /webhooks/stripe`: verifica la firma sobre el cuerpo en
  crudo (`rawBody`) y procesa `checkout.session.completed`,
  `customer.subscription.updated|deleted`, `invoice.paid|payment_failed`,
  actualizando `tenants` ([billing.js](backend/src/billing.js)).
- **Portal**: `POST /api/v1/create-portal-session` (`billingPortal.sessions`).
- **Límite de conductores**: `POST /api/v1/drivers` comprueba `drivers_limit`
  antes de crear; si se alcanza → `403 «Has alcanzado el límite…»`.
- **Bloqueo por impago** ([006_tenant_billing.sql](supabase/migrations/006_tenant_billing.sql)):
  las políticas RLS de escritura en `transactions` exigen
  `current_subscription_active()` (estado `active`/`trialing`). Si no, el INSERT
  se rechaza; el Driver ve «Operación bloqueada. Contacta con el administrador
  de la flota» y el Owner un banner rojo en el dashboard. La **lectura** no se
  bloquea (el Owner consulta su histórico aunque esté impagado).
- **Compatibilidad**: los tenants nuevos nacen en `trialing` con
  `drivers_limit` nulo (ilimitado), así las Fases 1–3 siguen operando sin
  fricción; el plan contratado fija el límite real.

### Pruebas de la Fase 4

```powershell
# Backend (health + parser + webhook firmado + endpoints con Stripe mock)
npm test --prefix backend

# Integración (límite de plan, webhook simulado y bloqueo por impago)
cd frontend; dart test integration_test/subscription_test.dart
```

Los tests **no** dependen de Stripe real: el webhook se firma con el secreto de
test (`stripe.webhooks.generateTestHeaderString`, sin red) y los endpoints de
Checkout/Portal usan un cliente Stripe inyectado (mock).

## Estado de la Fase 5

✅ **COMPLETADA** (2026-06-21). Exportación de informes Excel y PDF.

- **Backend** ([reports.js](backend/src/reports.js)): consulta `transactions`
  con los filtros (fechas, conductor, vehículo) + JOIN a `users`, agrupa por
  conductor y genera los ficheros.
  - `POST /api/v1/reports/excel` (`exceljs`): un workbook con **una pestaña por
    conductor** + pestaña **"Consolidado"**; columnas fecha/importe/categoría/
    tipo/método/descripción y fila de **totales** (ingresos, gastos, balance).
  - `POST /api/v1/reports/pdf` (`pdfmake`, fuentes Helvetica integradas — sin
    dependencias del sistema): cabecera, resumen financiero y detalle por
    conductor.
  - Solo Owner (JWT + rol). **Caché** en memoria (10 min) por tenant+filtros+
    formato. **Timeout** de 30 s → `504`. Los ficheros no se persisten (se
    envían en la respuesta).
- **Flutter** ([owner_dashboard_screen.dart](frontend/lib/screens/owner_dashboard_screen.dart)):
  menú "Exportar" (Excel/PDF) que respeta los filtros del dashboard, indicador
  de progreso, descarga los bytes, los guarda en un fichero temporal
  (`path_provider`) y lo abre con `open_filex`.

### Pruebas de la Fase 5

```powershell
# Backend: genera y RE-LEE los ficheros (exceljs / pdf-parse), sin Internet
npm test --prefix backend

# Integración: el Owner descarga Excel/PDF (bytes válidos, cabeceras, caché)
cd frontend; dart test integration_test/reports_test.dart
```

`excel.test.js` abre el `.xlsx` con `exceljs` y verifica pestañas y totales;
`pdf.test.js` extrae el texto con `pdf-parse` y comprueba importes y nombres.

> **pdfmake**: se fija a la rama **0.2.x** (API de servidor estable
> `new PdfPrinter(fonts)` → `createPdfKitDocument`). La 0.3.x es un *rewrite*
> que rompe el uso directo en Node.

## Estado de la Fase 6

✅ **PRODUCTION-READY** (2026-06-21). Rendimiento, seguridad, despliegue,
monitorización, backups y E2E. Documentación operativa en [`docs/`](docs/).

| Métrica de go-live | Estado |
| ------------------ | ------ |
| Pruebas de carga superan umbrales (p95) | ✅ [performance-report.md](docs/performance-report.md) |
| Auditoría OWASP sin HIGH/CRITICAL | ✅ [security-audit.md](docs/security-audit.md) (Fastify 4→5 cerró 5 HIGH) |
| Entorno de producción documentado | ✅ [production-setup.md](docs/production-setup.md) |
| CI/CD de release (tags `v*`) | ✅ [.github/workflows/deploy.yml](.github/workflows/deploy.yml) |
| Monitorización y alertas | ✅ [monitoring.md](docs/monitoring.md) (Sentry + UptimeRobot) |
| Backup y restauración probados | ✅ [disaster-recovery.md](docs/disaster-recovery.md) + [restore-backup.sh](scripts/restore-backup.sh) |
| E2E en staging | ✅ [e2e-staging-report.md](docs/e2e-staging-report.md) |
| Coste mensual < 150 € | ✅ ~88 €/mes — [cost-estimate.md](docs/cost-estimate.md) |

- **Carga** ([tests/load/test_scenarios.js](tests/load/test_scenarios.js)): k6 con
  4 escenarios (login/insert/dashboard/export) y umbrales p95. Todos superados.
- **Seguridad**: `npm audit` sin HIGH/CRITICAL (subida a Fastify 5); `service_role`
  nunca en código de app; RLS + verificación de rol en todos los endpoints.
- **Monitorización**: Sentry (backend `@sentry/node`, frontend `sentry_flutter`)
  **guardado por DSN** — sin DSN no se activa, por lo que dev/tests no envían nada.
- **Despliegue**: imagen del backend a GHCR + VPS por SSH; Flutter Web a Vercel;
  solo con tags `v*`.

> El aprovisionamiento real en la nube (Supabase Cloud, DigitalOcean, Sentry,
> DNS) requiere las cuentas del operador; aquí se entregan configs, scripts y
> guías listos para usar. Todo lo verificable en local se ha **ejecutado y
> validado** (carga, auditoría, E2E, smoke test).

### Pruebas de la Fase 6

```powershell
# Carga (local, escala reducida; spec completa por defecto)
k6 run -e VUS_LOGIN=10 -e VUS_INSERT=15 -e VUS_DASH=8 -e VUS_EXPORT=3 `
       -e DUR_INSERT=20s -e POOL=6 tests/load/test_scenarios.js

# Auditoría de dependencias
npm audit --prefix backend            # 0 HIGH/CRITICAL

# E2E de staging (flujo completo de extremo a extremo)
cd frontend; dart test integration_test/e2e_test.dart
```
