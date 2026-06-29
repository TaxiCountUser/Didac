# Retos épicos y recompensa trimestral de flota (Loop #4)

> Sistema de gamificación sostenible. Sustituye el modelo "1 mes gratis al JEFE
> por cada conductor que completa un ciclo" (insostenible: 100 conductores = >8
> años gratis) por uno **trimestral basado en el % de flota activa**.

## 1. Cómo funciona

### Conductores (sin cambios)
Cada conductor progresa en 3 retos épicos escalonados:

| Reto | Base (nivel 1) |
|---|---|
| `km_100k` | 100.000 km recorridos |
| `money_100k` | 100.000 € de balance |
| `days_300` | 300 días de uso |

Escalado en ciclos de 4 niveles: el 1.º de cada ciclo (niveles 1, 5, 9…) vuelve
a la base; los otros tres piden el doble. **Al alcanzar un reto, el logro se
registra automáticamente** (`challenge_claims.status = 'rewarded'`) y el
conductor avanza de nivel **sin aprobación manual**.

### Empresa (JEFE): recompensa trimestral
Al cierre de cada trimestre, para cada tenant se calcula:

- **active_drivers**: conductores `role='driver'`, `active=true`, con ≥1 lectura
  de km (`odometer_readings`) en los **últimos 30 días**.
- **drivers_with_achievement**: de los activos, los que tienen ≥1 logro
  (`challenge_claims` no rechazado) **creado dentro del trimestre** (DISTINCT).
- **completion_rate** = `drivers_with_achievement / active_drivers * 100`.

Recompensa (extiende `tenants.trial_ends_at`):

| Tasa | Días gratis |
|---|---|
| < 50 % | 0 |
| 50 % – 74,99 % | 7 |
| 75 % – 89,99 % | 15 |
| ≥ 90 % | 30 |

Máximo **30 días por trimestre** (≈ 4 meses/año como tope natural). El JEFE
recibe una notificación push con el resultado.

### Reglas de negocio
| ID | Regla |
|---|---|
| RN-05 | Cada conductor cuenta 1 sola vez en el numerador (DISTINCT por `user_id`). |
| RN-06 | Conductores sin km en 30 días no entran en el denominador. |
| RN-13 | Recompensa máxima 30 días/trimestre. |
| RN-21 | Los retos no se reinician: el numerador filtra por `created_at` dentro del trimestre. |

## 2. Esquema (migración 035)

- `fleet_quarterly_metrics` — 1 fila por `tenant_id + year + quarter`
  (`UNIQUE`). RLS: el owner ve su empresa; el admin de plataforma, todas.
- `cron_execution_logs` — auditoría de cada ejecución del cron (estado, tenants
  procesados, premios, detalle JSON). RLS: solo admin.

Aplicar en Supabase → SQL Editor ejecutando `supabase/migrations/035_*.sql`
(o el bloque 035 de `cloud_setup.sql`). Es **aditivo**: no toca datos existentes.

## 3. Cron / scheduler

Implementado en `backend/src/gamification.js` y arrancado desde `server.js`
(`scheduleQuarterly`) — **sin dependencias externas**:

- Comprueba 1 vez/hora si hoy es el **último día de un trimestre**
  (31 mar, 30 jun, 30 sep, 31 dic) y, a partir de las **23:00 UTC**, ejecuta el
  reparto del trimestre en curso.
- **Idempotente**: `upsert` sobre `UNIQUE(tenant_id, year, quarter)`, así que
  dispararlo más de una vez no duplica ni vuelve a premiar de forma incorrecta.
- No se activa en tests (`NODE_ENV=test`).

> Nota de fiabilidad: si el backend de Render se suspende por inactividad, el
> tick horario podría no dispararse. El endpoint manual de abajo sirve de red de
> seguridad (puede invocarse desde un scheduler externo: cron-job.org, GitHub
> Actions, etc., apuntando a la fecha de cierre de trimestre).

## 4. Probar manualmente (endpoint admin)

```bash
# Simulación: calcula y guarda métricas pero NO premia ni notifica.
curl -X POST https://<backend>/api/v1/admin/cron/quarterly-rewards \
  -H "Authorization: Bearer <TOKEN_ADMIN>" -H "Content-Type: application/json" \
  -d '{"dryRun": true}'

# Reparto real del trimestre actual.
curl -X POST https://<backend>/api/v1/admin/cron/quarterly-rewards \
  -H "Authorization: Bearer <TOKEN_ADMIN>" -H "Content-Type: application/json" -d '{}'

# Reparto de un trimestre concreto (re-procesar).
curl -X POST .../api/v1/admin/cron/quarterly-rewards \
  -H "Authorization: Bearer <TOKEN_ADMIN>" -H "Content-Type: application/json" \
  -d '{"year": 2026, "quarter": 2}'
```

Respuesta: `{ period, year, quarter, dryRun, tenants_processed, rewards_granted, duration_ms, results: [...] }`.

## 5. Endpoints del Dashboard del JEFE

| Endpoint | Descripción |
|---|---|
| `GET /api/v1/tenant/current-quarter-progress` | Progreso del trimestre en curso en tiempo real + `reward_days_projected`. |
| `GET /api/v1/tenant/quarterly-metrics?limit=&offset=` | Histórico de recompensas trimestrales (paginado). |

Solo `owner` (su tenant) o `admin` (puede consultar otro con `?tenant_id=`).
Rate limit básico: 100 req/min por usuario.

En la app, el **widget "Eficiencia de la flota"** y la **tabla de histórico**
aparecen en la pantalla de Retos (vista del empresario). La app del conductor no
cambia.

## 6. Panel de admin

La pestaña de Retos del admin ya **no muestra una cola de aprobaciones**: los
logros se registran solos. El admin solo puede **rechazar por fraude** un logro
(`status='rejected'`), lo que lo **excluye del cómputo trimestral**. El antiguo
botón "conceder mes gratis" se ha retirado; el endpoint
`POST /api/v1/admin/challenges/:id` ya no extiende ninguna suscripción.

## 7. Tests

- `backend/tests/unit/gamification.test.js` — funciones puras (tabla de
  recompensa, trimestres, último día de trimestre).
- `backend/tests/unit/fleet_rewards.test.js` — integración con Supabase mock:
  cálculo de métricas + RN-05/06/21 + fraude, reparto real (50 %→7 días) con
  extensión y push, `dryRun` e idempotencia.

Ambos en `npm test` y `npm run test:ci`.
