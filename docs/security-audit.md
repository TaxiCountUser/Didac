# Auditoría de seguridad — TaxiCount (Fase 6)

Revisión basada en **OWASP Top 10 (2021)**. Fecha: 2026-06-21.
Veredicto global: **sin hallazgos HIGH/CRITICAL pendientes**.

## Resumen de dependencias

| Componente | Herramienta | Resultado |
| ---------- | ----------- | --------- |
| Backend | `npm audit` | 5 HIGH → **0 HIGH** tras subir a Fastify 5; quedan 2 *moderate* (exceljs→uuid) aceptadas (ver abajo) |
| Frontend | `flutter pub outdated` | Sin avisos de seguridad; dependencias recientes y fijadas por rango |

### Detalle del fix de dependencias

Las 5 vulnerabilidades **HIGH** provenían de la cadena de **Fastify 4**
(`fast-uri` *path traversal* / *host confusion*, `fast-json-stringify`, y
`fastify` DoS + spoofing de `X-Forwarded-Proto/Host`). Se resolvieron
actualizando:

- `fastify` `^4.28.1` → `^5.8.5`
- `@fastify/cors` `^9` → `^10`
- `@fastify/multipart` `^8` → `^9`

Tras la actualización, `npm test` del backend sigue **100 % verde** (la API usada
—`register`, `inject`, `addContentTypeParser`, `decorate`, rutas— es compatible).

Las 2 **moderate** restantes son `exceljs` → `uuid <11.1.1` ("missing buffer
bounds check **cuando se pasa `buf`**"). exceljs genera UUIDs **sin** el argumento
`buf`, por lo que el camino vulnerable **no se ejercita**. Se acepta el riesgo
residual (no hay HIGH/CRITICAL) y se revisará cuando exceljs publique una versión
con uuid ≥ 11.1.1.

### Actualización 2026-10-11 (CI `audit-backend` + `deps-scan`)

`npm audit` y `osv-scanner` marcaron 31 avisos (21 HIGH) en transitivas del
backend, todos con versión parcheada **dentro del rango semver** (sin `--force`
ni overrides nuevos): `npm audit fix` + `fastify` `^5.8.5` → `^5.12.5`.
Versiones resueltas: `fastify` 5.12.5, `@grpc/grpc-js` 1.14.6
(GHSA-f596-whhp-79r4, GHSA-m9gg-hp2v-232j), `@fastify/busboy` 3.2.3,
`fast-uri` 3.1.8, `brace-expansion` 1.1.21 / 2.1.7, `qs` 6.16.0.
`npm audit` → **0 vulnerabilidades**; `npm test` y `test:ci` verdes.

## OWASP Top 10

### A01 — Broken Access Control ✅
- **RLS** activa en `tenants`, `users`, `vehicles`, `transactions`; aislamiento
  estricto por `tenant_id` con helpers `SECURITY DEFINER`
  (`current_tenant_id()`, `current_role_name()`, `current_subscription_active()`).
- Endpoints Fastify que usan `service_role` **siempre** filtran por el tenant del
  llamante (extraído del JWT verificado) o por eventos firmados de Stripe:
  - `POST /api/v1/drivers` → solo Owner; crea en `caller.tenant_id`.
  - `POST /api/v1/reports/{excel,pdf}` → solo Owner; consulta `tenant_id = caller`.
  - `POST /api/v1/create-checkout-session|create-portal-session` → solo Owner.
  - `POST /webhooks/stripe` → tenant resuelto por `metadata`/`stripe_customer_id`
    de un evento con **firma verificada**.
  - `POST /api/v1/transcribe` → opera sobre `caller.id`.
- No existe ningún endpoint que reciba un `tenant_id` arbitrario del cliente y lo
  use con `service_role` sin verificación.

### A02 — Cryptographic Failures ✅
- Comunicación por HTTPS en producción (Let's Encrypt, ver
  [production-setup.md](production-setup.md)).
- Contraseñas gestionadas por **GoTrue** (bcrypt); la app nunca las almacena.
- JWT firmado con `JWT_SECRET` (solo en el servidor). En producción debe ser un
  secreto fuerte y **distinto** del de demo local.

### A03 — Injection ✅
- Acceso a datos vía PostgREST/`supabase-js` con **consultas parametrizadas**;
  no se concatena SQL.
- RLS como segunda barrera incluso si una consulta se filtrara.
- El parser de voz es determinista (regex), sin `eval`.

### A04 — Insecure Design ✅
- Jerarquía Owner/Driver y límites de plan aplicados **en BD** (RLS + límite de
  conductores), no solo en la UI.
- Límite diario de transcripciones (coste/abuso) y bloqueo de escritura por
  impago a nivel RLS.

### A05 — Security Misconfiguration ✅
- `.env` **fuera de git** (`.gitignore`); solo se versiona `.env.example` con la
  clave **DEMO pública** y placeholders.
- `service_role` (la clave demo local) aparece únicamente en ficheros de test,
  `.env.example` y `kong/kong.yml` (config declarativa local). **No** está en
  `frontend/lib/**` ni en `backend/src/**` (el backend la lee de `process.env`).
- CORS configurado en Fastify; en producción conviene restringir `origin` al
  dominio de la web.

### A06 — Vulnerable & Outdated Components ✅
- Ver sección de dependencias: 0 HIGH/CRITICAL. `npm audit` integrable en CI.

### A07 — Identification & Authentication Failures ✅
- Autenticación gestionada por **Supabase GoTrue**: JWT de acceso con expiración
  (`JWT_EXPIRY`, 3600 s por defecto) y **refresh token** rotatorio
  (`autoRefreshToken` en el cliente). El backend valida cada token con
  `supabase.auth.getUser(token)` antes de operar.

### A08 — Software & Data Integrity Failures ✅
- Webhook de Stripe verifica la **firma** (`stripe.webhooks.constructEvent`)
  sobre el cuerpo en crudo; un payload sin firma válida → `400`.
- Imágenes Docker construidas desde fuente; despliegue por tags `v*`.

### A09 — Security Logging & Monitoring Failures ✅
- **Sentry** (backend + Flutter) y **UptimeRobot** sobre `/health`
  (ver [monitoring.md](monitoring.md)).

### A10 — Server-Side Request Forgery (SSRF) ✅
- El backend no hace fetch de URLs arbitrarias proporcionadas por el usuario.
  Las únicas salidas son a OpenAI y Stripe (endpoints fijos).

## XSS / CSRF
- Flutter (web/móvil) renderiza widgets, no HTML sin escapar.
- La autenticación viaja en cabecera `Authorization: Bearer`, **no en cookies**
  → no hay superficie CSRF clásica.

## Acciones recomendadas antes del go-live
1. Generar un `JWT_SECRET` fuerte y único en Supabase Cloud (no el de demo).
2. Restringir `CORS origin` al dominio de la web de producción.
3. Activar `npm audit --audit-level=high` como gate en CI.
4. Rotar claves si alguna vez se expuso la `.env` real.
