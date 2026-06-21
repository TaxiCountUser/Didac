# Informe de rendimiento — TaxiCount (Fase 6)

Pruebas de carga con [k6](https://k6.io). Script:
[`tests/load/test_scenarios.js`](../tests/load/test_scenarios.js).

> ⚠️ Las pruebas se ejecutan **solo contra local o staging**, nunca producción.

## Escenarios y umbrales (p95)

| Escenario | Carga (spec completa) | Umbral p95 |
| --------- | --------------------- | ---------- |
| a) Login simultáneo | 50 VUs | < 500 ms |
| b) Inserción de transacciones | 100 conductores, cada 10 s, 5 min | < 800 ms |
| c) Carga de dashboard con filtros | 20 Owners | < 1500 ms |
| d) Exportación Excel/PDF | 5 Owners concurrentes | < 10 000 ms |

El script admite la escala completa por defecto y una **escala reducida** por
variables de entorno (`VUS_LOGIN`, `VUS_INSERT`, `VUS_DASH`, `VUS_EXPORT`,
`DUR_INSERT`, `POOL`).

## Ejecución registrada (2026-06-21, local)

Entorno: stack `docker compose` en una sola máquina de desarrollo (Postgres +
PostgREST + Kong + Fastify en contenedores compartiendo CPU). Escala reducida
representativa (no hardware de producción):

```
k6 run -e VUS_LOGIN=10 -e VUS_INSERT=15 -e VUS_DASH=8 -e VUS_EXPORT=3 \
       -e DUR_INSERT=20s -e POOL=6 tests/load/test_scenarios.js
```

### Resultados

| Escenario | p95 medido | Umbral | Veredicto |
| --------- | ---------- | ------ | --------- |
| Login | **74.6 ms** | < 500 ms | ✅ |
| Inserción | **70.6 ms** | < 800 ms | ✅ |
| Dashboard | **8.7 ms** | < 1500 ms | ✅ |
| Exportación | **80.0 ms** | < 10 000 ms | ✅ |

- **checks**: 605/605 (100 %), `http_req_failed` 0.00 %.
- Todos los umbrales `p(95)` se cumplen con amplio margen.

### Notas

- Los tiempos locales son muy bajos porque no hay latencia de red ni
  contención real; sirven para validar el script y detectar regresiones
  groseras. La **validación oficial de los umbrales debe repetirse en staging**
  sobre infraestructura de tamaño producción (Supabase Pro + VPS) y a **escala
  completa** (50/100/20/5 VUs) antes del go-live de cada release mayor.
- Índices relevantes ya presentes (Fase 3,
  [`005_indexes.sql`](../supabase/migrations/005_indexes.sql)):
  `(tenant_id, created_at)`, `(user_id, created_at)`, `created_at` — la consulta
  del dashboard (`order by created_at desc limit 20`) los usa, de ahí el p95 de
  milisegundos.
- La exportación se beneficia de la **caché de 10 min** del backend
  ([`reports.js`](../backend/src/reports.js)): tras la primera generación, las
  siguientes peticiones con los mismos filtros son casi instantáneas.

## Cuellos de botella y mitigaciones

| Riesgo | Mitigación implementada |
| ------ | ----------------------- |
| Consultas de listado lentas | Índices compuestos por `tenant_id`/`user_id` + `created_at` |
| Exportaciones costosas | Caché 10 min + timeout 30 s (`504`) + paginación interna |
| Transcripciones (coste/latencia) | Límite diario por usuario (429) + caché en memoria |
| Saturación de escritura | RLS ligera (helpers `SECURITY DEFINER`, sin recursión) |
