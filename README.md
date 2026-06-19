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
