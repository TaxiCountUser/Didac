# Monitorización y alertas — TaxiCount (Fase 6)

## Sentry (errores y trazas)

Captura de excepciones en backend y frontend. **Desactivado por defecto**: solo
se activa si se proporciona el DSN, así que dev/tests no envían nada.

### Backend (Fastify)
- SDK: `@sentry/node`. Se inicializa en `buildApp()` solo si existe `SENTRY_DSN`
  y registra `Sentry.setupFastifyErrorHandler(app)`.
- Variables: `SENTRY_DSN`, opcional `SENTRY_TRACES_SAMPLE_RATE` (def. 0.1),
  `NODE_ENV` (environment).

### Frontend (Flutter)
- SDK: `sentry_flutter`. Se inicializa en `main()` solo si el dart-define
  `SENTRY_DSN` no está vacío:
  ```bash
  flutter build web --dart-define=SENTRY_DSN=https://<key>@oXXXX.ingest.sentry.io/YYYY
  ```

### Acceso y triage
1. Dashboard: https://sentry.io → proyectos `taxicount-backend` y
   `taxicount-flutter`.
2. Cada *issue* trae stack trace, breadcrumbs y entorno. Asignar y etiquetar por
   severidad.
3. Configurar alertas de Sentry (email/Slack) para *new issue* y picos de error.

## UptimeRobot (disponibilidad)

1. Crear monitor **HTTP(s)** sobre `https://api.taxicount.app/health` cada
   **5 min** (https://uptimerobot.com, plan gratuito).
2. Palabra clave esperada: `"status":"ok"`.
3. Contactos de alerta: email/SMS/Slack del equipo de guardia.
4. Crear también un monitor para la web `https://taxicount.app`.

## Qué hacer si salta una alerta

| Síntoma | Acción inmediata |
| ------- | ---------------- |
| UptimeRobot: `/health` caído | Revisar la App en DO (logs, reinicio); comprobar Supabase status. |
| Sentry: pico de 5xx | Abrir el issue, identificar endpoint; si es regresión de un release, *rollback* al tag anterior (`docker pull ...:<tag-previo>`). |
| Sentry: errores de auth (401 masivos) | Verificar `JWT_SECRET` y estado de GoTrue en Supabase. |
| Errores de Stripe webhook (400) | Revisar `STRIPE_WEBHOOK_SECRET`; reenviar eventos desde el panel de Stripe. |
| Latencia alta | Revisar [performance-report.md](performance-report.md); comprobar índices y plan de Supabase. |

## Métricas operativas a vigilar
- p95 de `/api/v1/*` (objetivos en [performance-report.md](performance-report.md)).
- Uso de transcripciones por día (límite diario por usuario ya implementado).
- Estado de suscripciones (`past_due`/`canceled`) en `tenants`.
- Espacio y conexiones de Postgres en el panel de Supabase.
