# Runbook de incidentes — TaxiCount

> Qué hacer cuando algo está en rojo. Una página. Si llegas aquí desde un email
> del "Vigía de semáforos" o de UptimeRobot, busca el semáforo y sigue los pasos.
> Panel: app web → admin → Seguridad → pestaña **Semáforos**.

## Enlaces rápidos

| Qué | Dónde |
|---|---|
| Backend (logs y env) | dashboard.render.com → `taxicount-backend` → Logs / Environment |
| Base de datos | supabase.com/dashboard → proyecto → Database / Logs / Reports |
| Workflows (crons, backup, vigía) | github.com → repo → Actions |
| Errores de código | sentry.io → proyecto `taxicount-backend` |
| Uptime externo | uptimerobot.com → dashboard |
| Pagos | dashboard.stripe.com → Developers → Webhooks (intentos y errores) |

## Por semáforo

### 🔴 API (o UptimeRobot avisa de caída)
**Significa:** el backend de Render no responde.
1. Render → Logs: ¿crash-loop? ¿deploy reciente roto? (el último deploy sale arriba).
2. Si es un deploy malo: Render → Rollback al deploy anterior (1 clic).
3. Si Render está caído (status.render.com), esperar; la app web sigue leyendo
   de Supabase (solo fallan voz, informes, admin y Stripe).

### 🔴 BD (database: error o "Lento")
**Significa:** la sonda a Supabase falla o tarda >800 ms.
1. Supabase → Reports: CPU, conexiones, disco. ¿Algo al 100%?
2. Supabase → Database → Query performance: ¿alguna consulta disparada?
3. Si es saturación sostenida: subir compute add-on (Settings → Add-ons).
4. Si Supabase está caído (status.supabase.com), esperar y avisar en el banner
   de mantenimiento (admin → Config → mantenimiento ON con mensaje).

### 🔴 CRONS (challenge_credits / referral_validations: stale)
**Significa:** las recompensas/validaciones no corren desde hace >48h.
1. GitHub → Actions → "Crons de recompensas": ¿último run verde? ¿deshabilitado?
   (GitHub pausa schedules tras 60 días sin commits — botón "Enable workflow").
2. Ejecutarlo a mano: Run workflow. Si falla: ¿CRON_SECRET cambiado en Render
   pero no en GitHub Secrets (o al revés)? Deben ser idénticos.
3. Son idempotentes: ejecutarlos de más no duplica recompensas.

### 🔴 BACKUP (stale)
**Significa:** no hay copia de la BD desde hace >48h. **Prioridad máxima.**
1. GitHub → Actions → "Backup diario de la BD": ver el error del último run.
2. Causa típica: `SUPABASE_DB_URL` caducada/rotada → regenerar en Supabase
   (Connect → Session pooler) y actualizar el secret en GitHub.
3. Lanzarlo a mano y comprobar que el semáforo vuelve a verde.

### 🔴 STRIPE (error)
**Significa:** la firma de un webhook NO verificó. O bien alguien manda payloads
falsos (raro), o bien `STRIPE_WEBHOOK_SECRET` está mal/rotado. **Cobros y accesos
pueden estar desincronizándose.**
1. Stripe → Developers → Webhooks → endpoint: ver intentos fallidos y el error.
2. Si el secret rotó: copiar el nuevo "Signing secret" → Render → Environment →
   `STRIPE_WEBHOOK_SECRET` → Save.
3. Tras arreglar: Stripe permite **reenviar** los eventos fallidos desde el
   panel (Resend) — hacerlo para recuperar los perdidos.

### 🔴 WHISPER / OPENAI (error)
**Significa:** la última transcripción / llamada al parser LLM falló.
Impacto: la entrada por voz cae al modo manual; la app sigue funcionando.
1. Render → Logs: buscar "Whisper falló" o "LLM parse falló" (motivo exacto).
2. Causas típicas: API key caducada o sin crédito (OpenAI/Groq), o timeout.
3. Probar tras el arreglo: admin → cualquier `/parse-test`, o una nota de voz.

### 🔴 PUSH (error)
**Significa:** el envío a Firebase (FCM) falló (credenciales, no tokens sueltos).
1. Render → Logs: "[push] envío FCM falló" o "no se pudo inicializar FCM".
2. Causa típica: service account de Firebase rotada → regenerar JSON en Firebase
   Console → actualizar la env var en Render.

### ⚪ never ("Sin datos")
No es avería: ese semáforo aún no ha registrado ningún evento (p. ej. despliegue
nuevo). El vigía NO alerta por esto.

## Escalada

1. ¿Afecta a cobros (STRIPE) o a datos (BD/BACKUP)? → se arregla HOY.
2. ¿Afecta a una función auxiliar (voz, push)? → puede esperar a mañana.
3. Si hay que parar la app: admin → Config → **modo mantenimiento** con mensaje
   (banner a todos los usuarios) mientras se trabaja.
4. Tras cada incidente: 3 líneas en `docs/incidentes.md` (fecha, causa, fix).
   Lo que se repite dos veces merece automatización.
