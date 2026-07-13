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
- [x] **M2-5. Procesamiento asíncrono (tras feature flag).** *HECHO (2026-07-13)*:
  con el flag `webhook_async` ON, el handler persiste el evento y responde 200 al
  instante (`{queued:true}`); el cron `retry-webhooks` drena la bandeja
  (`drainWebhookQueue` procesa `error` + `received` antiguos, con corte de edad
  `WEBHOOK_RECEIVED_MIN_AGE_MS` para no pisar al handler síncrono). Si la bandeja
  no está disponible, cae a síncrono (nunca pierde el evento). **Arranca OFF**: con
  los números del load test no hace falta aún; queda montado y probado. Test de
  integración en webhook.test.js (flag ON → `queued` sin aplicar inline → drenaje
  aplica → `past_due`).
- [x] **M2-6. Reproceso de la bandeja.** *HECHO (2026-07-13)*: endpoint/cron
  `POST /api/v1/admin/cron/retry-webhooks` (`drainWebhookQueue`) reintenta los
  eventos en `error` reusando su `payload` vía `handleStripeEvent` (idempotente);
  tope `WEBHOOK_MAX_ATTEMPTS=6` → al agotarse pasan a `dead`. La cadencia del cron
  (workflow `retry-webhooks.yml`, cada 15 min) actúa de backoff. Semáforo
  `webhook_errors` (cuenta `error`+`dead` + `received` atascados; >0 → rojo) en
  `computeSemaphores`, en el dashboard (`webhook_errors` + resta 10 de salud) y
  pill WEBHOOKS en el home; el vigía externo ya lo alerta. Test de integración en
  webhook.test.js (siembra un evento `error` → retry → `processed` + tenant activo).

## Fase 3 — Cutover seguro

- [x] **M2-7. Feature flag.** *HECHO (2026-07-13)*: interruptores de plataforma en
  `system_config` (prefijo `flag_`), con caché corta y allowlist (`webhook_async`).
  Endpoints `GET/POST /api/v1/admin/flags` (adminGuard + auditoría `flag_set`) y
  **toggle en el panel** (Auditoría → Semáforos). Rollback sin deploy.
- [x] **M2-8. Observabilidad del camino async (en vez de shadow run).**
  *HECHO (2026-07-13)*: ambos modos ejecutan la MISMA función idempotente, así que
  una comparación viejo/nuevo es redundante. La verificación real es operativa: el
  semáforo WEBHOOKS marca *atascados* (`received` > 10 min = el drenaje no avanza)
  además de *rotos*. Decisión razonada en el manual de cutover.
- [x] **M2-9. Cutover + runbook.** *HECHO (2026-07-13)*: procedimiento de
  activación, validación 24-48 h y **rollback** documentado en
  [manual-m2-cutover.md](manual-m2-cutover.md). No se elimina la ruta síncrona: se
  conserva a propósito como fallback bajo el flag (es lo que permite el rollback).

## Criterio de salida del Mes 2

1. Ningún evento de Stripe se pierde ante un crash/redeploy (persistido en `webhook_events`). ✅
2. Un reintento de Stripe nunca duplica efectos (idempotencia probada en CI). ✅
3. La lógica de billing vive en un módulo testeado, no incrustada en el handler. ✅
4. Hay visibilidad de eventos fallidos (semáforo/bandeja) y forma de reprocesarlos. ✅

**▶ MES 2 CERRADO (2026-07-13).** Billing aislado, idempotente, durable, con
procesamiento async conmutable y rollback sin deploy. Siguiente: Mes 3 (agregación
del dashboard al backend + caché — el primer límite que midió el load test).

## Fuera de alcance (más adelante)
- Escrituras de alta frecuencia por backend con pool controlado → 100k+ (ver anexo de load-test-t8.md).
- Read replicas / caché de dashboard → Mes 3.
