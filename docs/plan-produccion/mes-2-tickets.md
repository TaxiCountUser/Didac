# Plan de producción — Mes 2: Strangler-Fig del billing

> Objetivo: aislar y endurecer el módulo de pagos (el de mayor riesgo-negocio)
> con bisturí, no reescritura. Red de seguridad ya lista: CI de integración en
> verde testea webhook + billing contra BD real en cada push.
>
> **Por qué billing primero:** es el camino del dinero, y estáis a punto de
> cobrar de verdad. Un webhook perdido/duplicado = cliente sin acceso o cobro
> doble. Aquí es donde un fallo silencioso cuesta un cliente.

## Fase 1 — Idempotencia + durabilidad del webhook ✅ (2026-07-11)

- [x] **M2-1. Tabla `webhook_events`** — migración 062: registra cada evento de
  Stripe por `event_id` (dedup), con `payload` para reproceso. Solo backend
  (service_role; RLS sin políticas). **PENDIENTE ejecutar en Supabase Cloud.**
- [x] **M2-2. Handler idempotente y durable** — `/webhooks/stripe` ahora:
  1. registra el evento como `received` (con payload) antes de procesar;
  2. si el `event_id` ya está `processed`, responde `{duplicate:true}` sin
     reprocesar (Stripe reintenta a menudo → nunca doble cobro/acceso);
  3. al acabar marca `processed`; si falla, deja `error` + `last_error` y
     devuelve 500 (Stripe reintenta; applyStripeEvent es idempotente).
  **Todo best-effort:** si la tabla no existe aún en prod, el webhook funciona
  igual que antes (nunca rompemos el camino del dinero).
- [x] **M2-3. Test de idempotencia** — webhook.test.js: reenviar el mismo evento
  no reprocesa (verde en el job de integración del CI). Event ids únicos por run.

## Fase 2 — Extracción del módulo (Strangler-Fig)

- [x] **M2-4. Interfaz limpia de billing** — *HECHO (2026-07-11)*: `handleStripeEvent(supabase, event, deps)` en billing.js orquesta applyStripeEvent + efectos de referidos (inyectados). El handler HTTP solo hace firma/idempotencia/ACK. 3 tests de orquestación en billing_logic.test.js (CI). Sustituye a la lógica antes incrustada en server.js. Definir el contrato del módulo
  (entradas/salidas) y mover a `billing.js` todo lo que hoy vive en el handler
  de server.js (side-effects de referidos incluidos) detrás de una función
  única `handleStripeEvent(supabase, event, deps)`.
- [ ] **M2-5. Procesamiento asíncrono (opcional según carga).** Responder 200 a
  Stripe al registrar el evento y procesar desde la bandeja (cron corto que
  drena `webhook_events` en estado `received`/`error`). Reduce timeouts y
  desacopla el ACK del trabajo. Evaluar si hace falta (hoy el proceso es rápido).
- [ ] **M2-6. Reproceso de la bandeja.** Endpoint/cron
  `/admin/cron/retry-webhooks` que reintenta los `error` con backoff y tope de
  `attempts`. Semáforo nuevo: eventos en `error` > 0.

## Fase 3 — Cutover seguro

- [ ] **M2-7. Feature flag** de la ruta nueva (tabla `feature_flags` o GrowthBook)
  para poder volver atrás sin deploy.
- [ ] **M2-8. Shadow run + comparación** (si se hace async): correr viejo y nuevo
  en paralelo y comparar resultados antes de cortar.
- [ ] **M2-9. Cutover + limpieza** del código viejo.

## Criterio de salida del Mes 2

1. Ningún evento de Stripe se pierde ante un crash/redeploy (persistido en `webhook_events`).
2. Un reintento de Stripe nunca duplica efectos (idempotencia probada en CI). ✅
3. La lógica de billing vive en un módulo testeado, no incrustada en el handler.
4. Hay visibilidad de eventos fallidos (semáforo/bandeja) y forma de reprocesarlos.

## Fuera de alcance (más adelante)
- Escrituras de alta frecuencia por backend con pool controlado → 100k+ (ver anexo de load-test-t8.md).
- Read replicas / caché de dashboard → Mes 3.
