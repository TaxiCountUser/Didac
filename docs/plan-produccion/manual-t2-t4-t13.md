# Manuales paso a paso — T2 (pooler), T4 (alertas Sentry), T13 (UptimeRobot)

> Los tres se hacen desde paneles web, sin tocar código. Tiempo total: ~1 h 45 min.
> Prerrequisito ya cumplido: T1 (Supabase Pro) y migración 061 ejecutada. ✅

---

## T2 — Pooler de conexiones (Supavisor) · ~20 min

### Contexto (léelo, cambia lo que hay que hacer)

Auditado el código: el backend de Render se conecta a Supabase **solo vía
`supabase-js` (HTTP/PostgREST)**, que ya usa el pool interno de Supabase.
**No hay nada que cambiar en Render.** Las únicas conexiones DIRECTAS a
Postgres las hacen:

1. el **backup diario** (`backup-db.yml` → secret `SUPABASE_DB_URL`), y
2. el script local `scripts/backup-db.ps1`.

Objetivo real de T2: que esas conexiones directas usen el **Session pooler**
(y no la conexión directa), y dejar el pooler verificado para cuando en el
Mes 3 añadamos algo con conexión directa (colas, rollups).

### Pasos

1. Entra en [supabase.com/dashboard](https://supabase.com/dashboard) → tu proyecto.
2. Botón **"Connect"** (arriba, junto al nombre del proyecto).
3. En la pestaña de cadenas de conexión verás 3 modos:
   - **Direct connection** (puerto 5432, host `db.<ref>.supabase.co`) — evitar.
   - **Transaction pooler** (puerto **6543**) — para apps con muchas conexiones cortas.
   - **Session pooler** (puerto **5432**, host `aws-0-<region>.pooler.supabase.com`) —
     el que quieres para `pg_dump` (necesita sesión completa).
4. Copia la URI de **Session pooler** y ponle la contraseña de la BD
   (Settings → Database → Database password → Reset si no la tienes).
5. GitHub → repo → **Settings → Secrets and variables → Actions** →
   edita **`SUPABASE_DB_URL`** → pega la URI del Session pooler.
6. **Verifica**: Actions → "Backup diario de la BD" → **Run workflow**.
   Debe acabar en verde y el semáforo BACKUP del panel de admin en verde.
7. (Opcional) Actualiza la misma URI en tu `.env` local si usas `backup-db.ps1`.

**Hecho cuando:** el backup manual pasa en verde usando la URI del pooler.

---

## T4 — Alertas de Sentry · ~1 h

### Contexto

Sentry ya está integrado en el backend (`@sentry/node`, activado por DSN).
Sin alertas configuradas, los errores se acumulan sin que nadie los vea.
Vamos a crear 2 alertas mínimas y útiles (sin ruido).

### Prerrequisito: comprobar que el DSN está activo

1. [sentry.io](https://sentry.io) → tu organización → **Projects**.
   Debe existir el proyecto del backend y recibir eventos.
2. Si NO hay proyecto o no llegan eventos: crea proyecto (Platform: Node.js),
   copia el **DSN** y añádelo en **Render → tu servicio → Environment →
   `SENTRY_DSN`** → Save (redeploy automático). Fuerza un error de prueba
   (p. ej. una URL inexistente `/api/v1/no-existe` no genera error 500; mejor:
   espera al primer error real o usa el snippet de verificación de Sentry).

### Alerta 1 — Nuevo tipo de error (Issue Alert)

1. Sentry → **Alerts** → **Create Alert**.
2. Tipo: **Issues** → "Errors: New Issue" (o "When: a new issue is created").
3. Proyecto: el backend. Entorno: production.
4. Condición: *A new issue is created* → **then** notify.
5. Acción: **Send a notification to email** (tu correo) — o Slack si lo conectáis.
6. Nombre: `Backend · error nuevo` → **Save rule**.

### Alerta 2 — Pico de errores (Metric Alert)

1. **Alerts** → **Create Alert** → tipo **Metric** → "Number of Errors".
2. Proyecto backend, filtro `event.type:error`.
3. Umbral: **> 10 errores en 5 minutos** → Critical (ajústalo tras 1 semana:
   si nunca salta, bájalo; si salta a diario, súbelo o arregla la causa).
4. Acción: email. Nombre: `Backend · pico de errores` → **Save**.

### (Opcional, 15 min) Lo mismo para el frontend web
Si tenéis proyecto de Sentry para Flutter web, repite las 2 alertas sobre él.

**Hecho cuando:** recibes el email de prueba de cada alerta (Sentry permite
"Send Test Notification" al editar la regla).

---

## T13 — UptimeRobot sobre /health · ~15 min

### Contexto

Chequeo EXTERNO: si Render entero se cae, ningún cron interno avisará.
UptimeRobot (gratis: 50 monitores, chequeo cada 5 min) vigila desde fuera.

### Pasos

1. Crea cuenta en [uptimerobot.com](https://uptimerobot.com) (Free).
2. **+ New monitor**:
   - Monitor type: **HTTP(s)**.
   - Friendly name: `TaxiCount backend`.
   - URL: `https://taxicount-backend.onrender.com/health`.
   - Interval: **5 minutes**.
3. **Alert contacts**: tu email (viene por defecto). Añade el del otro dev
   (My Settings → Add Alert Contact) y márcalo en el monitor.
4. **+ New monitor** (segundo, la web):
   - URL: `https://taxicountuser.github.io/Didac/` — type HTTP(s), 5 min.
5. **Verifica**: pausa el monitor y reactívalo, o espera el primer ciclo:
   el dashboard debe mostrar "Up" en verde con el tiempo de respuesta.
6. (Opcional, 5 min) **Status page**: Status Pages → Add — te da una página
   pública de estado que puedes enseñar a clientes/inversores.

**Hecho cuando:** ves ambos monitores "Up" y te llega el email de bienvenida
del monitor (o el de "Down→Up" si probaste la pausa).

---

## Después de completar los tres

Marca T2/T4/T13 en [mes-1-tickets.md](mes-1-tickets.md). Con eso, del Mes 1
solo quedan: T5 (log drain), T7 (simulacro de restore), T8/T9 (load test) y
T11/T12 (aviso de semáforos + runbook) — estos dos últimos los puede hacer
Claude Code.
