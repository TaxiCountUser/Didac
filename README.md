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
