# Informe Fase 0 — DevEnvironmentBootLoop

**Fecha:** 2026-06-19
**Resultado final:** ✅ ÉXITO — smoke test E2E con exit 0, reproducible desde cero.

## Resumen

El entorno arrancó de cero (sin Docker/Node/Flutter instalados). Tras instalar
el toolchain y resolver 6 incidencias de configuración, el loop converge: arranque
limpio (`down -v` → `up -d --build`) con todos los servicios *healthy* y el smoke
test pasando sin intervención manual.

## Incidencias encontradas y corregidas

1. **Entorno sin toolchain.** No había Docker, Node ni Flutter.
   → Node se instaló con `winget` (v24.17.0). Docker Desktop lo instaló el usuario
   (requiere admin + reinicio + distro WSL2). Ver [INSTALL.md](INSTALL.md).

2. **CLI de Docker más nuevo que el motor (API 1.54 vs 1.51).** Todo respondía
   HTTP 500 mientras Docker Desktop terminaba de arrancar.
   → Se resolvió solo al iniciar del todo Docker Desktop; se dejó
   `DOCKER_API_VERSION=1.51` como red de seguridad.

3. **Roles de sistema sin contraseña.** GoTrue (`supabase_auth_admin`) y PostgREST
   (`authenticator`) fallaban con *password authentication failed*.
   → Script de init `supabase/scripts/00-roles.sh` (montado en
   `/docker-entrypoint-initdb.d`) que fija contraseñas y grants.

4. **Backend crash-loop: Node 20 sin WebSocket nativo** (lo exige
   `@supabase/supabase-js`).
   → `backend/Dockerfile` actualizado a `node:22-alpine`.

5. **`uuid_generate_v4()` / `crypt()` no encontradas.** Las extensiones viven en el
   esquema `extensions`, fuera del `search_path`.
   → La migración usa `gen_random_uuid()` (core de PG15); el seed usa un
   placeholder en `password_hash` (las credenciales las gestiona GoTrue).

6. **Kong no sustituye variables de entorno** en su config declarativa → apikeys
   inválidas (401). Y las claves demo de Supabase **no estaban firmadas** con
   nuestro `JWT_SECRET` (JWSInvalidSignature en PostgREST).
   → Se generaron claves `anon`/`service_role` firmadas con el secreto local y se
   hardcodearon en `kong.yml` (y `.env`, smoke-test, frontend).

7. **PostgREST con caché de esquema vacía** (arrancó antes de crearse las tablas):
   lectura OK pero escritura 404.
   → `apply.sh` emite `NOTIFY pgrst, 'reload schema'` tras migraciones+seed.

8. **Backend *unhealthy* pese a funcionar:** el healthcheck usaba `localhost`
   (resuelto a IPv6 `::1`) y Fastify escucha en IPv4 `0.0.0.0`.
   → Healthcheck cambiado a `http://127.0.0.1:3000/health`.

## Verificación final

```
docker compose down -v && docker compose up -d --build
# db, auth, kong, backend -> healthy ; db-init -> exited 0 (NOTIFY enviado)
node smoke-test/test.js
# ✅ SMOKE TEST OK — entorno dev validado  (exit 0)
```

El smoke test valida: login owner/driver, creación de vehículo por owner,
inserción de transacción por driver, visibilidad RLS del owner sobre su tenant,
y aislamiento estricto (lectura y escritura) frente a otro tenant.
