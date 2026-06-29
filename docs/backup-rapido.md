# Copia de seguridad rápida — TaxiCount

> Objetivo: poder **guardar todos los datos en 2 minutos** antes de tocar nada,
> y poder **volver atrás** si algo sale mal. Pensado para Windows + PowerShell.
> Para el plan de recuperación completo (caídas del servidor, etc.) ver
> [disaster-recovery.md](disaster-recovery.md).

## Backup automático diario (nuevo)

Hay un **backup automático cada día (~03:00 hora de España)** mediante GitHub
Actions: [.github/workflows/backup-db.yml](../.github/workflows/backup-db.yml).
Hace `pg_dump` del esquema `public` y lo guarda como **artefacto** del workflow
con **90 días de retención** (Actions → "Backup diario de la BD" → run → Artifacts).

- **Requisito (una vez):** en GitHub → Settings → Secrets and variables → Actions,
  añade `SUPABASE_DB_URL` con la cadena de conexión (URI) de Supabase
  (usa el **Session pooler** si la conexión directa IPv6 falla).
- Se puede lanzar a mano: Actions → "Backup diario de la BD" → **Run workflow**.
- Para descargas/restauración manual sigues teniendo `scripts/backup-db.ps1`.

> No sustituye a los backups del plan Pro de Supabase (PITR); es una copia
> adicional, barata y sin servicios extra.

## Qué hay que proteger (y qué no)

| Cosa | ¿Hay que hacer backup manual? | Por qué |
| --- | --- | --- |
| **El código** (Flutter + backend) | ❌ No | Ya está en GitHub. Cada commit es un punto de restauración. |
| **El esquema** (tablas, funciones, RLS) | ❌ No | Está en `supabase/migrations/` + `supabase/cloud_setup.sql`, en GitHub. |
| **Los DATOS de los usuarios** (empresas, carreras, gastos, tickets…) | ✅ **SÍ** | Viven solo en **Supabase Cloud**. Si se borran o corrompen, no están en GitHub. |

**Conclusión:** lo único que de verdad puede "sufrir pérdidas" son los **datos en
Supabase**. Por eso este documento se centra en ellos.

---

## Regla de oro antes de cualquier cambio

> **Antes de modificar el esquema (SQL) o de subir una versión que cambia datos:
> haz un backup de los datos.** Tarda 2 minutos y te ahorra un disgusto.

Flujo seguro recomendado:

1. **Backup** de los datos (Nivel 1 o Nivel 2, abajo).
2. Aplicar el cambio (re-ejecutar `cloud_setup.sql` o una migración nueva).
   - Las migraciones de TaxiCount son **idempotentes** (`if not exists`,
     `create or replace`): re-ejecutarlas **no borra ni duplica** nada.
3. Probar en la app que todo funciona.
4. Si algo va mal → **restaurar** el backup (ver más abajo).

---

## Nivel 1 — Backup desde el panel de Supabase (lo más fácil, sin instalar nada)

### 1a) Backups automáticos (si tienes plan Pro)
- Supabase **Pro** hace **backups diarios automáticos** con 7 días de retención.
- Panel → **Database → Backups**. Ahí puedes ver los diarios y **restaurar** con
  un clic a un día anterior.
- En plan **Free NO hay** backups automáticos → usa el backup manual de abajo.

### 1b) Backup manual de datos (cualquier plan)
1. Panel de Supabase → **SQL Editor**.
2. Para una tabla concreta, abre **Table Editor → (tabla) → menú "···" → Export
   to CSV**. Repite con las tablas importantes: `tenants`, `users`,
   `transactions`, `vehicles`, `incidents`, `incident_messages`, `referrals`.
3. Guarda los CSV en una carpeta con la fecha (p. ej. `backup_2026-06-27/`).

> El Nivel 1b es rápido pero parcial (CSV por tabla). Para una copia **completa y
> restaurable de golpe**, usa el Nivel 2.

---

## Nivel 2 — Backup completo a un archivo en tu PC (recomendado antes de cambios grandes)

Genera **un único archivo** con TODO el esquema `public` + datos, listo para
restaurar. Usa **Docker** (que ya tienes), así que **no necesitas instalar nada**.

### Paso 1: consigue tu cadena de conexión
Panel de Supabase → **Project Settings → Database → Connection string → URI**.
Tiene esta forma (incluye tu contraseña, **no la compartas con nadie**):

```
postgresql://postgres:TU_PASSWORD@db.xxxxxxxx.supabase.co:5432/postgres
```

### Paso 2: ejecuta el script
En PowerShell, dentro de la carpeta del proyecto:

```powershell
./scripts/backup-db.ps1
```

Te pedirá la cadena de conexión (se escribe **solo en tu PC**, nunca sale de ahí)
y creará un archivo con fecha en `./backups/`, por ejemplo:

```
backups/taxicount_20260627_0148.dump
```

Ese `.dump` es tu foto completa. Guárdalo en sitio seguro (disco, nube personal).

---

## Restaurar (volver atrás si algo salió mal)

### Opción A — desde el panel (si usas Pro)
Panel → **Database → Backups → Restore** al día anterior al problema. Es lo más
limpio si tienes backups automáticos.

### Opción B — desde tu archivo `.dump` del Nivel 2
> ⚠️ Restaurar **sobre producción** sobrescribe datos. Hazlo solo si estás
> seguro, e idealmente prueba antes en local.

Para **probar/inspeccionar** un backup en local sin tocar producción:

```bash
# (en Git Bash, con el stack local de Supabase arrancado)
SOURCE_DB_URL="postgresql://postgres:PASS@db.<ref>.supabase.co:5432/postgres" \
  ./scripts/restore-backup.sh
```

Ese script **nunca** escribe en un host de Supabase (tiene una salvaguarda): solo
restaura en tu Postgres local, ideal para verificar que el backup está sano.

---

## Buenas prácticas para que "todo salga bien" al implementar cosas nuevas

1. **Rama por feature**: trabaja en una rama (`feature/loquesea`), no en `main`,
   hasta que esté probado. Así `main` siempre está estable.
2. **Migraciones nuevas, no edites las viejas**: añade `030_xxx.sql`,
   `031_xxx.sql`… y **anéxalas también a `cloud_setup.sql`**. Hazlas idempotentes
   (`if not exists`, `create or replace`, `drop ... if exists`).
3. **Backup antes de aplicar SQL** en producción (Nivel 2).
4. **Prueba primero en local** (Docker) o en un proyecto de staging de Supabase
   antes de tocar el de producción.
5. **Confirma el backend** tras desplegar:
   `curl.exe -s https://taxicount-backend.onrender.com/health`
6. **Nunca borres datos a mano** en producción sin backup previo.

---

## Resumen de un vistazo

| Quiero… | Hago… |
| --- | --- |
| Backup rápido antes de un cambio | `./scripts/backup-db.ps1` (Nivel 2) |
| Backup sin instalar nada | Panel → Table Editor → Export CSV (Nivel 1b) |
| Volver a ayer (plan Pro) | Panel → Database → Backups → Restore |
| Probar que un backup sirve | `./scripts/restore-backup.sh` en local |
| Comprobar que el backend vive | `curl.exe -s …onrender.com/health` |
