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
- [ ] **M3-2. RPC `period_report`** — mismo patrón para el cierre de jornada:
  ingresos por método + gasto + balance agregados en SQL. La parte de km/horas
  (primera/última lectura por conductor+vehículo con relleno retroactivo) se
  mantiene en cliente de momento (lógica compleja, pocas filas de odómetro), o
  se pasa a SQL en una 2ª iteración. Fallback a la ruta antigua.

## Fase 2 — Rollups diarios (cuando el volumen lo pida)

- [ ] **M3-3. Tabla `tenant_daily_rollup`** (tenant_id, day, user_id, income,
  expense, tx_count) mantenida de forma incremental (trigger en `transactions` o
  cron nocturno) + backfill. Mes/año pasan a sumar ~30-365 filas de rollup en vez
  de miles de tx crudas. **Gatillo de activación:** cuando una flota supere
  ~50k tx/mes o el p95 del resumen anual > 800 ms. Hasta entonces, M3-1 basta.
- [ ] **M3-4. Caché corta de agregados (opcional).** Si se enruta el resumen por
  el backend Fastify, TTL 15-30 s por (tenant, filtros, rango) para colapsar
  refrescos repetidos. Se evalúa tras medir; los rollups pueden hacerla innecesaria.

## Fase 3 — Verificación

- [ ] **M3-5. Re-medir con k6** (mismos perfiles de T8) tras M3-1/2: confirmar que
  la cola p95 de dashboard baja del umbral (1500 ms) a 500 VUs. Actualizar
  load-test-t8.md con la nueva fila.

## Criterio de salida del Mes 3

1. El resumen del dashboard se agrega en la BD, no trayendo filas al cliente.
2. Fallback a la ruta antigua: ningún despliegue puede dejar el dashboard en blanco.
3. Re-medido: la agregación deja de ser el primer límite (o se documenta el nuevo).

## Fuera de alcance (más adelante)
- Read replicas (solo si una réplica de lectura se justifica por métricas reales).
- Enrutar escrituras de alta frecuencia por el backend con pool controlado → 100k+
  (anexo de load-test-t8.md, stress 10k).
