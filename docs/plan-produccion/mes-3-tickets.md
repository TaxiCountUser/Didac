# Plan de producción — Mes 3: agregación del dashboard + caché/rollups

> Objetivo: eliminar el **primer límite medido** en el load test (T8): la
> agregación del dashboard bajo concurrencia de paneles. Hoy el cliente trae
> TODAS las filas del periodo y suma en el navegador → a un mes/año de una flota
> grande son miles de filas por cada refresco. Lo movemos a la BD (SUM/GROUP BY)
> y, cuando el volumen lo pida, a rollups diarios.
>
> Regla de oro: **no romper el camino de lectura del dinero**. Cada cambio lleva
> fallback a la ruta antigua, así el orden de despliegue (migración vs web) no
> importa.

## Diagnóstico (dónde está el coste)

| Consulta | Hoy | Coste |
|---|---|---|
| `transactionsSummary` (KPIs del dashboard Owner) | trae `amount,type,category` de **todas** las tx del rango → suma en cliente | O(filas): un mes de flota = miles de filas por panel |
| `periodReport` (cierre de jornada / semana / mes / año) | trae todas las tx + odómetros del rango → agrega en cliente | O(filas) + lógica km/horas en cliente |
| lista de tx (feed) | PostgREST `limit=20` con joins | acotada; no es el cuello |

El load test marcó cola p95 **solo** en la ventana de 30 paneles refrescando en
bucle: es la agregación, no la escritura (insert p95 102 ms a 1.000 VUs).

## Fase 1 — Agregar en la BD (sin cambiar el modelo)

- [x] **M3-1. RPC `report_summary`** — *HECHO (2026-07-13)*: función SQL
  `stable` (INVOKER) en migración 063 que devuelve `{income, expense,
  expense_by_category}` con `SUM ... FILTER` + `GROUP BY` en la BD. La RLS limita
  tenant + rol (owner: todo; conductor: lo suyo); filtro explícito
  `tenant_id = current_tenant_id()` para que con service_role (RLS off) devuelva
  vacío, no todo. El cliente (`transactionsSummary`) llama por `rpc()` y **cae a la
  agregación antigua** si la RPC no está (despliegue sin acoplar). Reduce
  transferencia O(filas) → O(1). **Verificado contra el stack real**
  (report_summary.test.js, en el job de integración de CI): agregados correctos,
  aislamiento entre tenants (RLS) y filtro de fechas. **PENDIENTE aplicar mig. 063
  en Supabase Cloud** (hasta entonces, el fallback mantiene el dashboard vivo).
- [x] **M3-2. RPC `period_report`** — *HECHO (2026-07-13)*: migración 064. Agrega
  en SQL el dinero del cierre de jornada (income, expense, income_by_method) y las
  **ventanas de actividad por día** (`tx_activity` = min/max de `created_at` por día
  local, con `p_offset` del cliente) para el cálculo de horas. La parte de **km**
  (odómetros con relleno retroactivo) y el cómputo final de **horas** se mantienen
  IDÉNTICOS en cliente — no se regresiona el cierre de jornada (que ya se arregló
  por el bug de timezone); solo se elimina el pull masivo de transacciones. El
  cliente alimenta `mark()` con las ventanas (equivale a marcar todas las tx, solo
  cuenta el min/max del día). Fallback a traer filas si la RPC no está. Verificado
  contra el stack real (period_report.test.js): dinero, por-método, ventana de
  actividad, aislamiento entre tenants y rango de fechas. **PENDIENTE aplicar mig.
  064 en Supabase Cloud** (hasta entonces, el fallback cubre).

## Fase 2 — Rollups diarios ✅ (2026-07-13)

- [x] **M3-3. Tabla `tenant_daily_rollup`** — *HECHO*: migración 065.
  `(tenant_id, user_id, day, income, expense, tx_count, income_by_method,
  expense_by_category, first_at, last_at)`, PK (tenant,user,day), RLS igual que
  `transactions`. Mantenida **incremental y exacta** por trigger
  `tx_rollup_aiud` sobre `transactions` (insert/update/delete → recompute del
  bucket afectado, acotado por rango de `created_at` para no escanear el histórico;
  buckets vacíos se borran). Día natural LOCAL vía `report_tz()` ('Europe/Madrid')
  para casar con los rangos del cliente. Backfill de los datos existentes al final.
  RPCs de lectura `report_summary_rollup` / `period_report_rollup` (mismo shape que
  063/064). El cliente las usa para rangos ≥60 días sin filtro por vehículo/cliente,
  con fallback en cadena a las RPCs crudas y a la agregación en cliente. Verificado
  contra el stack real (rollups.test.js): **rollup == crudo** (exactitud), trigger
  en insert/update/delete, borrado de bucket vacío y aislamiento por tenant.
- [x] **M3-4. Caché de agregados** — *RESUELTO por los rollups*: los rollups hacen
  cada resumen O(días) en vez de O(tx), así que una caché con TTL sería redundante
  y añadiría staleness sobre el camino del dinero. No se implementa; si en el
  futuro hiciera falta, el sitio sería un TTL corto en el backend Fastify.

> **Gatillo de uso del cliente:** las RPCs de rollup solo se invocan en rangos
> grandes (mes/año). Día/semana y vistas filtradas siguen por la RPC cruda (ya
> rápida). Así el rollup añade valor donde importa sin cambiar el resto.

> **Nota de coste de escritura:** el trigger recalcula un bucket pequeño (las tx de
> ese conductor ese día, por índice user+created) en cada insert. Insignificante al
> volumen actual y muy por encima. A escritura extrema (100k+) se puede desacoplar
> a mantenimiento asíncrono por cron (dirty buckets); anotado, no accionable hoy.

## Fase 3 — Verificación

- [x] **M3-5. Re-medir con k6** — *HECHO (2026-07-13)*: escenario `dashboard`
  actualizado para llamar a la RPC + A/B con `DASH_MODE` (rpc vs legacy) y siembra
  `SEED_TX`. A 50k tx / 30 paneles: RPC **3,4× mejor p95** (0,95 s vs 3,23 s),
  **~20× menos datos** (48 MB vs 979 MB), **+52% throughput**; legacy cruza la SLA
  de 1500 ms, RPC no. Detalle y matiz honesto (localhost oculta el coste de red →
  la mejora en Cloud es mayor) en el anexo de
  [load-test-t8.md](load-test-t8.md).

## Criterio de salida del Mes 3

1. El resumen del dashboard se agrega en la BD, no trayendo filas al cliente. ✅ (M3-1/M3-2)
2. Fallback a la ruta antigua: ningún despliegue puede dejar el dashboard en blanco. ✅
3. Re-medido: la agregación deja de ser el primer límite. ✅ (3,4× p95, 20× datos; A/B M3-5)

**▶ NÚCLEO DEL MES 3 CERRADO (2026-07-13).** La agregación del dashboard vive en la
BD (RPCs), no escala con el nº de filas, y se mantiene dentro de la SLA a 100× el
volumen actual. Rollups (M3-3/4) quedan gated hasta que el volumen los justifique.

## Fuera de alcance (más adelante)
- Read replicas (solo si una réplica de lectura se justifica por métricas reales).
- Enrutar escrituras de alta frecuencia por el backend con pool controlado → 100k+
  (anexo de load-test-t8.md, stress 10k).
