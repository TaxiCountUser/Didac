# T8 — Load test con k6: perfiles listos (100 / 500 / 1000 conductores)

> Objetivo: saber a cuántos conductores concurrentes aguanta la plataforma HOY
> (p95 por endpoint + CPU/conexiones de la BD) ANTES de que lo descubra una flota.
> El script ya existe: `tests/load/test_scenarios.js` (login, insert, dashboard, export).

## ⚠️ Regla de oro: NO contra producción

El script **crea conductores de prueba e inserta carreras** (usa la service key).
Contra prod ensuciaría los datos reales. Dos opciones:

- **Opción A (recomendada): staging desechable en Supabase.** Crea un proyecto
  NUEVO gratis en supabase.com (p. ej. `taxicount-staging`), aplícale las
  migraciones (SQL editor → pegar los .sql en orden, o `psql` con la URI) y
  apunta el test ahí. Al acabar, borra el proyecto. Mide comportamiento real de
  Supabase (red incluida); ten en cuenta que Free ≈ menos CPU que vuestro Pro,
  así que el resultado es un SUELO (prod Pro rendirá mejor).
- **Opción B: stack local** (`docker compose up -d`). Mide los límites de la
  app y las queries (relativo), pero no la capacidad real de Supabase Cloud.

El backend para el escenario export/transcribe puede ser el local
(`npm start` en backend/ apuntando al staging con SUPABASE_URL/SERVICE key).

## Instalar k6 (Windows)

```powershell
winget install k6 --source winget    # o: choco install k6
k6 version
```

## Los 3 perfiles

Ejecutar desde la raíz del repo. Sustituye `<URL>` y las claves si usas staging
(Opción A); con el stack local (Opción B) los defaults ya valen.

```powershell
# Variables comunes para staging (Opción A); omítelas en local:
$env:BASE_URL   = "https://<ref>.supabase.co"     # URL del proyecto staging
$env:ANON_KEY   = "<anon key del staging>"
$env:SERVICE_KEY= "<service key del staging>"
$env:BACKEND_URL= "http://localhost:3000"          # backend local apuntando al staging
```

**Perfil 1 — 100 conductores** (~6 min):

```powershell
k6 run -e VUS_LOGIN=20 -e VUS_INSERT=100 -e VUS_DASH=10 -e VUS_EXPORT=3 `
       -e DUR_INSERT=5m -e POOL=25 tests/load/test_scenarios.js
```

**Perfil 2 — 500 conductores** (~6 min):

```powershell
k6 run -e VUS_LOGIN=50 -e VUS_INSERT=500 -e VUS_DASH=30 -e VUS_EXPORT=5 `
       -e DUR_INSERT=5m -e POOL=50 tests/load/test_scenarios.js
```

**Perfil 3 — 1000 conductores** (~8 min):

```powershell
k6 run -e VUS_LOGIN=100 -e VUS_INSERT=1000 -e VUS_DASH=60 -e VUS_EXPORT=8 `
       -e DUR_INSERT=5m -e POOL=80 tests/load/test_scenarios.js
```

> VUS_INSERT ≈ conductores activos insertando; VUS_DASH ≈ jefes con el panel
> abierto (~6% de los conductores); POOL = conductores reales creados en setup.

## Qué anotar en cada perfil (la chuleta del T8)

| Métrica | Dónde | Umbral de alarma |
|---|---|---|
| p95 login | salida k6 (`http_req_duration{scenario:login}`) | > 500 ms |
| p95 insert | salida k6 (insert_tx) | > 800 ms |
| p95 dashboard | salida k6 (dashboard) | > 1500 ms |
| p95 export | salida k6 (export) | > 10 s |
| Errores (http_req_failed) | salida k6 | > 1% |
| CPU de la BD | Supabase → Reports (staging) | > 70% sostenido |
| Conexiones | Supabase → Reports | cerca del máximo del plan |

**El resultado del T8 es una frase:** «Aguantamos ~N conductores concurrentes;
el primer límite es X» (p. ej. "p95 del dashboard a 500 VUs" o "CPU BD al 90%
a 1000 VUs"). Apúntala aquí debajo y esa frase decide el T9 (qué optimizar) y
si el Mes 3 necesita read-replica o basta con caché.

## Resultados (rellenar al ejecutar)

| Fecha | Perfil | p95 login/insert/dash/export | Errores | CPU BD | Veredicto |
|---|---|---|---|---|---|
| — | 100 | — | — | — | — |
| — | 500 | — | — | — | — |
| — | 1000 | — | — | — | — |
