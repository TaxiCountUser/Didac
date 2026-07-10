# Manuales — T5 (logs), T7 (simulacro de restore) y T8 (load test)

> Los últimos 3 tickets del Mes 1. T7 ya está automatizado (solo hay que
> mirar el resultado); T5 y T8 son vuestros, con pasos exactos.

---

## T5 — Logs con retención (app → Better Stack) · ~15 min

### Para qué
Poder responder "¿qué pasó ayer a las 8:03?" sin estar mirando la consola en
ese momento.

### ⚠️ Cambio de plan (2026-07-11)
Los **Log Streams nativos de Render exigen workspace Professional** (19 $/us/mes);
el workspace es Hobby y no aparece el menú. Solución implementada en código:
el backend envía los logs **directamente** a Better Stack con un transporte de
pino (`@logtail/pino`). Se activa solo si existe la env var
`LOGTAIL_SOURCE_TOKEN`; sin ella, todo sigue como siempre (stdout). Los logs
siguen viéndose también en la consola de Render.

### Pasos (solo panel, sin código)

1. Cuenta gratis en [betterstack.com](https://betterstack.com) (mismo email
   compartido que Sentry). Producto: **Telemetry → Logs**.
2. **Sources → Connect source** → plataforma **"Node.js / Pino"** (o JavaScript)
   → te da un **source token** y un **ingesting host**
   (p. ej. `sXXXX.eu-nbg-2.betterstackdata.com`).
3. **Render** → servicio `taxicount-backend` → **Environment** → añade:
   - `LOGTAIL_SOURCE_TOKEN` = el source token.
   - `LOGTAIL_INGESTING_HOST` = el ingesting host (sin `https://`).
   - Save → redeploy automático (~2 min).
4. **Verifica**: abre la app web (genera tráfico) → Better Stack → **Live tail**
   → deben aparecer las líneas JSON de Fastify en <1 min.
5. (Opcional, 10 min) Alerta en Better Stack sobre `"level":50` (errores de
   pino) → email. Complementa a Sentry.

**Hecho cuando:** ves logs del backend en Live tail y sabes buscar por texto/fecha.

---

## T7 — Simulacro de restauración · AUTOMATIZADO ✅

### Qué se ha hecho
Workflow **"Simulacro de restauración"** (`restore-drill.yml`): descarga el
último backup diario, levanta un Postgres 17 limpio, restaura el dump con
`pg_restore` y verifica los datos (tablas + filas de tenants/users/transactions).
Si falta algo, el run **falla** → email de GitHub. Se ejecuta **el día 1 de
cada mes** y a mano cuando quieras (Actions → Simulacro de restauración →
Run workflow). El resumen (duración, recuentos) queda en la pestaña **Summary**
de cada run.

### Lo que aún es manual (una vez al trimestre, ~15 min)
El simulacro prueba el DUMP sobre Postgres vanilla. Una restauración REAL
sobre Supabase (proyecto nuevo) tiene 2 pasos más que conviene ensayar una vez:
1. Crear proyecto Supabase vacío → aplicar migraciones (o restaurar directamente
   el dump con `pg_restore` a su URI del Session pooler).
2. Smoke test con la app apuntando a ese proyecto (`--dart-define SUPABASE_URL=...`).
Los detalles están en [docs/disaster-recovery.md](../disaster-recovery.md).

---

## T8 — Load test · guía completa en [load-test-t8.md](load-test-t8.md)

Resumen ultra-corto de lo que os toca:

1. Crear proyecto **staging desechable** en Supabase (gratis, 5 min).
2. Aplicarle las migraciones (SQL editor, en orden 001→061).
3. `winget install k6`.
4. Ejecutar los **3 comandos ya preparados** (perfiles 100/500/1000) del doc.
5. Apuntar los resultados en la tabla del doc (p95 + errores + CPU de la BD).
6. Borrar el proyecto staging.

**El entregable es una frase:** "aguantamos ~N conductores; el primer límite es X".
Esa frase decide el T9 y el diseño del Mes 3.
