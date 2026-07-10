# Plan de producción — Mes 1: Estabilización y observabilidad (tickets)

> Objetivo del mes: pasar de "beta con 11 conductores en Free tier" a "plataforma
> que aguanta la primera flota real sin sustos". Presupuesto: ~35-60 €/mes.
> Equipo: 1 FTE (2 devs a media jornada) + Claude Code.
>
> Estado inicial auditado el 2026-07-08. Los tickets ✅ ya están hechos (algunos
> existían de antes y solo hubo que verificarlos; otros se entregan con este plan).

## Semana 1 — Salir de Free + ver lo que pasa

- [x] **T1. Supabase → plan Pro** — *HECHO (2026-07-10)*.
- [x] **T2. Pooler de conexiones (Supavisor)** — *HECHO (2026-07-10)* *(~20 min)* — **re-alcance
  (2026-07-10)**: auditado el código, el backend solo usa supabase-js (REST,
  pool interno de Supabase) → **no hay nada que cambiar en Render**. Lo que sí:
  apuntar el secret `SUPABASE_DB_URL` (backup diario) al **Session pooler** y
  verificar con un backup manual. Manual paso a paso en
  [manual-t2-t4-t13.md](manual-t2-t4-t13.md).
- [x] **T3. Render always-on con health check** — *ya existente, verificado*:
  `render.yaml` tiene `plan: starter`, `healthCheckPath: /health` y
  `autoDeploy: true`. Render solo enruta tráfico a instancias sanas → deploy
  roto no recibe tráfico (cero-downtime básico).
- [x] **T4. Alertas de Sentry** — *HECHO (2026-07-10: sentry:true + 2 alertas)* *(~1 h)*
  Sentry ya está integrado (guardado por DSN). Configurar en el panel de Sentry:
  alerta por **pico de error-rate** (backend y Flutter web) y por **primer error
  nuevo** → email/Slack. Sin alertas, Sentry es un cementerio de errores.
- [ ] **T5. Logs estructurados con retención** *(~2 h)*
  Fastify ya usa pino. Añadir **log drain** de Render a Better Stack (Logtail,
  tier gratis) para retener y buscar logs. Regla mínima: poder responder "¿qué
  pasó ayer a las 8:03?" sin SSH.

## Semana 2 — Base de datos: índices y restauración

- [x] **T6. Índices de escala** — *entregado*: migración
  [061_perf_indexes_scale.sql](../../supabase/migrations/061_perf_indexes_scale.sql).
  Nota: los índices críticos de `transactions` **ya existían** (005:
  tenant+created, user+created, created). La 061 añade los 2 que faltaban:
  `app_usage_days(tenant_id, day)` (cron de retos) y
  `odometer_readings(user_id, taken_at)` (cierre de jornada del conductor).
  **Ejecutada en Supabase Cloud el 2026-07-10.** ✅
- [x] **T7. Simulacro de restauración** — *HECHO y AUTOMATIZADO (2026-07-11)*: workflow "Simulacro de restauración" (mensual + manual) que restaura el último backup en un Postgres limpio y verifica los datos. Primer run en verde: 28 tablas, 13 tenants, 17 users, 365 transactions restauradas en 1 s. Manual del ensayo trimestral sobre Supabase real en [manual-t5-t7-t8.md](manual-t5-t7-t8.md).
  Un backup sin restore probado NO es un backup. Con el workflow diario
  (backup-db.yml) ya en marcha: descargar el último dump → restaurarlo en un
  proyecto Supabase vacío (o docker local) → smoke test contra él. Documentar
  los pasos y el tiempo real en docs/disaster-recovery.md.

## Semana 3 — Load test: encontrar el límite ANTES que los clientes

- [ ] **T8. Load test con k6** *(~2 h, PREPARADO)* — guía con los 3 perfiles listos y tabla de resultados en [load-test-t8.md](load-test-t8.md); solo falta ejecutarlos (staging desechable, NO prod).
  Ya existen escenarios en `tests/load/test_scenarios.js`. Ejecutarlos contra
  **staging/producción actual** con perfiles de 100 / 500 / 1.000 conductores
  virtuales (login + insert + dashboard). Anotar: p95 por endpoint, CPU de la
  BD (panel de Supabase), conexiones. **El número que salga = tu capacidad
  real hoy.**
- [ ] **T9. Arreglar las 2 queries más lentas del load test** *(~4 h)*
  Con `explain analyze` sobre las que salgan peor. Candidatas probables: las
  agregaciones del dashboard (suman `transactions` del periodo en el cliente)
  y las RPC de retos. No optimizar nada que el load test no señale.

## Semana 4 — Alertas de negocio + runbook

- [x] **T10. Semáforos de plataforma** — *ya existente*: 9 semáforos (API, BD
  con latencia, crons, backup, Stripe, Whisper, OpenAI, Push) en el panel de
  admin + log en Auditoría.
- [x] **T11. Notificación externa cuando un semáforo pase a rojo** — *entregado (2026-07-10)*: endpoint GET /admin/cron/semaphores (x-cron-secret) + workflow "Vigía de semáforos" cada 15 min; si algo está stale/error el run FALLA y GitHub avisa por email.
  Los semáforos hoy hay que MIRARLOS. Añadir al backend un chequeo (cron cada
  15 min vía GitHub Actions, mismo patrón que cron-rewards.yml) que llame a
  `/api/v1/admin/semaphores` con el cron-secret y mande email/Telegram si algo
  está `stale`/`error`. Un semáforo rojo a las 3:00 debe despertar a alguien.
- [x] **T12. Runbook de incidentes** — *entregado (2026-07-10)*: [docs/runbook.md](../runbook.md), 1 página por semáforo con primeros pasos y escalada.
  docs/runbook.md: por cada semáforo, qué significa el rojo, primer comando a
  ejecutar, cómo escalar. 1 página. Se escribe una vez, se agradece siempre.
- [x] **T13. UptimeRobot (o Better Stack) sobre /health** *(~15 min, gratis)*
  Chequeo externo cada 1-5 min + página de estado. Si Render entero se cae,
  ningún cron interno te va a avisar.

## CI — el camino del dinero testeado de verdad

- [x] **T14. Job de integración en CI** — *entregado*: nuevo job
  `test-backend-integration` en ci.yml que levanta el stack Supabase con docker
  compose y ejecuta **de verdad** webhook + billing + excel + pdf.
  Con `CI_REQUIRE_STACK=1`: si el stack no arranca, el job **falla** (no se
  omite). El dinero ya no se refactoriza a ciegas.
  **Verificado en verde el 2026-07-10** (run 29125574982): 6 tests de webhook +
  4 de billing + 5 de excel + 3 de pdf ejecutados contra el stack real.

## Fuera de alcance del Mes 1 (no lo hagas todavía)

- Read replicas, Redis/caché, colas → Mes 3, solo si el load test lo justifica.
- Strangler-Fig de billing → Mes 2 (con el CI de integración ya en verde).
- Migrar a AWS → no. Revisar recién hacia 100k+ conductores.
- **Push en primer plano** (banner con la app abierta, tipo WhatsApp): listener
  de `onMessage` + `flutter_local_notifications` en push_service.dart. Hoy la
  notificación solo se muestra con la app en segundo plano/cerrada (verificado
  2026-07-11 al probar el arreglo de FCM). Pequeño y útil; para después del Mes 1.

## Criterio de salida del Mes 1 (definition of done)

1. Supabase Pro + pooler activos; 061 aplicada.
2. Un deploy roto no tumba producción (health check verificado con un deploy de prueba).
3. Sabes tu capacidad real en nº de conductores concurrentes (dato del load test).
4. Un backup restaurado con éxito, con los pasos documentados.
5. Cualquier semáforo en rojo genera una notificación que llega al móvil.
6. CI en verde **incluyendo** los tests de integración del webhook.
