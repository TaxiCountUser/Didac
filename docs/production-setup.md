# Puesta en producción — TaxiCount (Fase 6)

Guía operativa para desplegar TaxiCount. Requiere cuentas propias (Supabase,
DigitalOcean, dominio, Vercel/Netlify). Coste objetivo: **< 150 €/mes** (ver
[cost-estimate.md](cost-estimate.md)).

Arquitectura de producción:

```
Flutter Web (Vercel/Netlify)  ─┐
Flutter móvil (stores)         ─┤── HTTPS ──> api.taxicount.app (Fastify, DO App Platform)
                                │                     │
                                └────────────────────┴──> Supabase Cloud (Pro)
                                                            (Postgres + Auth + Realtime + Storage)
Stripe  <── webhooks ──>  api.taxicount.app/webhooks/stripe
OpenAI Whisper  <──  api.taxicount.app/api/v1/transcribe
```

## 1. Supabase Cloud (plan Pro, ~25 €/mes)

1. Crear proyecto en https://supabase.com (región EU, p. ej. `eu-west-1`).
2. Anotar `Project URL`, `anon key` y `service_role key` (Settings → API).
3. Generar un **`JWT_SECRET` fuerte y único** (Settings → API → JWT). No usar el
   de demo local.
4. Migrar el esquema. Opción A (Supabase CLI):
   ```bash
   supabase link --project-ref <ref>
   supabase db push          # aplica supabase/migrations/*.sql en orden
   ```
   Opción B (psql directo):
   ```bash
   for f in supabase/migrations/*.sql; do psql "$DATABASE_URL" -f "$f"; done
   ```
   > El seed (`supabase/seed.sql`) es **solo para local**; no cargarlo en prod.
5. Realtime: añadir `transactions` a la publicación (ya lo hace
   `006`... la 005 lo incluye de forma idempotente). En Cloud, además activar la
   tabla en Database → Replication si hiciera falta.
6. Auth: confirmar expiración de JWT (3600 s) y refresh tokens activados.
   Configurar plantillas de email y `Site URL`.
7. Storage: crear el bucket `voice-notes` (privado) para las notas de voz.

## 2. Backend Fastify (DigitalOcean App Platform, ~12 €/mes)

Usa el [`backend/Dockerfile`](../backend/Dockerfile) existente.

1. Crear una App en DO App Platform a partir del repo (carpeta `backend/`) o de
   una imagen en GHCR (ver [CI/CD](#4-cicd)).
2. Configurar variables de entorno (App → Settings → Environment):
   | Variable | Valor |
   | -------- | ----- |
   | `SUPABASE_URL` | URL del proyecto Supabase Cloud |
   | `SUPABASE_SERVICE_ROLE_KEY` | service_role de Supabase (secreto) |
   | `OPENAI_API_KEY` | clave de OpenAI |
   | `STRIPE_SECRET_KEY` | `sk_live_...` |
   | `STRIPE_WEBHOOK_SECRET` | `whsec_...` del endpoint de producción |
   | `STRIPE_PRICE_STARTER/PRO/BUSINESS` | Price IDs reales (modo live) |
   | `ALLOW_MOCK_TRANSCRIBE` | `false` (¡importante en prod!) |
   | `SENTRY_DSN` | DSN del backend (opcional) |
   | `CORS_ORIGIN` | `https://taxicount.app` |
   | `BACKEND_PORT` | `3000` |
3. Health check: `GET /health` (HTTP, puerto 3000).
4. Escalado: 1 instancia `basic-xs` cubre el MVP; aumentar si la carga lo exige.

## 3. Dominios y SSL

1. Comprar `taxicount.app` y delegar DNS al proveedor.
2. `api.taxicount.app` → App de DO (registro CNAME/A según DO). SSL automático
   (Let's Encrypt gestionado por DO).
3. `taxicount.app` y `www` → Vercel/Netlify (SSL automático).
4. Configurar el **webhook de Stripe** apuntando a
   `https://api.taxicount.app/webhooks/stripe` y copiar el `whsec_...` a la env.

## 4. Flutter Web (Vercel/Netlify, gratis)

```bash
cd frontend
flutter build web --release \
  --dart-define=SUPABASE_URL=https://<ref>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<anon> \
  --dart-define=BACKEND_URL=https://api.taxicount.app \
  --dart-define=STRIPE_PRICE_STARTER=price_live_... \
  --dart-define=STRIPE_PRICE_PRO=price_live_... \
  --dart-define=STRIPE_PRICE_BUSINESS=price_live_...
# Publicar el contenido de build/web
```
En Vercel/Netlify, configurar el directorio de salida `build/web` y SPA fallback
a `index.html`.

## 5. Móvil (opcional)

`flutter build apk --release` / `flutter build ipa --release` con los mismos
`--dart-define`. Subir a Google Play / TestFlight como beta.

## Checklist de go-live

- [ ] Migraciones aplicadas en Supabase Cloud (sin seed).
- [ ] `ALLOW_MOCK_TRANSCRIBE=false` en el backend de prod.
- [ ] `JWT_SECRET` único y fuerte.
- [ ] CORS restringido al dominio web.
- [ ] Webhook de Stripe (live) configurado y verificado.
- [ ] SSL válido en `taxicount.app` y `api.taxicount.app`.
- [ ] Sentry + UptimeRobot activos ([monitoring.md](monitoring.md)).
- [ ] Backups verificados ([disaster-recovery.md](disaster-recovery.md)).
