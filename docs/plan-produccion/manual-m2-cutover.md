# Manual — Cutover a webhooks asíncronos (Mes 2, M2-5/7/8/9)

> Objetivo: activar el procesamiento **asíncrono** del webhook de Stripe en
> producción, con red de seguridad y **rollback en segundos sin redeploy**.

## Qué cambia

- **Modo síncrono (por defecto, flag OFF):** el webhook aplica el evento inline y
  responde a Stripe cuando ha terminado. Es el comportamiento de siempre.
- **Modo asíncrono (flag ON):** el webhook verifica la firma, persiste el evento
  en la bandeja `webhook_events` (`received`) y **responde 200 al instante**. El
  cron `retry-webhooks` (cada 15 min) drena la bandeja y aplica los eventos.

En ambos modos el evento se persiste **antes** de procesar, así que nunca se
pierde ante un crash/redeploy. Si la bandeja no estuviera disponible (BD caída),
el webhook **cae automáticamente a síncrono** para no perder el evento.

## Por qué es seguro

- `applyStripeEvent` es **idempotente**: reprocesar un evento no duplica efectos.
- El flag vive en `system_config` (`flag_webhook_async`), conmutable desde el
  panel → **rollback instantáneo sin deploy**.
- El semáforo **WEBHOOKS** se pone rojo si quedan eventos rotos (`error`/`dead`)
  **o** atascados (`received` > 10 min = el drenaje async no avanza). El vigía
  externo y el panel avisan.

## Pre-requisitos (una vez)

1. El cron `retry-webhooks.yml` está activo (Actions → "Reproceso de webhooks
   Stripe"). Es quien drena la bandeja en modo async. Verifica que corre verde.
2. Migración 062 (`webhook_events`) aplicada en Supabase Cloud. ✅ (ya hecha)

## Activación (cutover)

1. **Panel admin → Auditoría → Semáforos.** Arriba verás *Interruptores de
   plataforma*. Activa **"Procesar los webhooks de Stripe en asíncrono"**.
   - Equivalente por API: `POST /api/v1/admin/flags` con `{"name":"webhook_async","on":true}`
     (Bearer de admin).
   - Equivalente por SQL (emergencia):
     `insert into system_config(key,value) values('flag_webhook_async','on')
      on conflict (key) do update set value='on';`
2. **Lanza un evento de prueba** desde Stripe (o una checkout real de test). El
   webhook debe responder `{"received":true,"queued":true}` y el tenant **no**
   cambia hasta que el cron drena (o hasta que fuerces el drenaje, paso 3).
3. **Fuerza un drenaje** para no esperar 15 min: Actions → "Reproceso de webhooks
   Stripe" → *Run workflow*. Verifica en el panel que el tenant quedó aplicado y
   que el semáforo WEBHOOKS sigue verde (0 rotos, 0 atascados).

## Validación (primeras 24-48 h)

- Vigila el semáforo **WEBHOOKS** en el panel (y el email del vigía externo).
  - Verde = la bandeja se drena a tiempo.
  - Rojo por *atascados* = el cron no está drenando → revisa el workflow
    `retry-webhooks.yml` (¿secrets `PROD_BACKEND_URL`/`CRON_SECRET`?).
  - Rojo por *rotos* = un evento falla al aplicar → mira `last_error` en
    `webhook_events` (se reintenta hasta 6 veces; luego pasa a `dead`).
- Confirma que ninguna suscripción se queda en estado incorrecto tras un pago.

## Rollback (si algo va mal)

**Apaga el flag** — vuelta al modo síncrono al instante, sin deploy:

- Panel → Semáforos → desactiva el interruptor, **o**
- `POST /api/v1/admin/flags` `{"name":"webhook_async","on":false}`, **o**
- SQL: `update system_config set value='off' where key='flag_webhook_async';`

Los eventos que quedaran encolados (`received`) los aplica igualmente el próximo
drenaje del cron; no se pierde nada. A partir de ese momento los nuevos eventos
se procesan inline como antes.

## Nota sobre "shadow run" (M2-8)

El plan contemplaba correr viejo y nuevo en paralelo y comparar. Como **ambos
modos ejecutan la MISMA función idempotente** (`handleStripeEvent`) sobre el mismo
payload, el resultado es idéntico por construcción: una comparación redundante no
aporta señal. La verificación real del camino async es **operativa** (¿drena la
bandeja a tiempo?), y eso lo cubre el semáforo WEBHOOKS (rotos + atascados) más el
vigía externo. Decisión pragmática, no omisión.

## Estado de M2-5 (procesamiento asíncrono)

Con los números del load test (proceso rápido, sin cola), el async **no es
necesario hoy**; queda montado y probado para activarlo cuando el volumen o la
latencia del webhook lo pidan. Por eso el flag arranca **OFF**.
