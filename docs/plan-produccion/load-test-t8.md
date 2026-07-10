# T8 — Load test con k6: manual paso a paso

> Objetivo: una frase — «aguantamos ~N conductores concurrentes; el primer
> límite es X». Duración total: ~2 h. NUNCA contra producción (el test crea
> usuarios e inserta carreras).
>
> Requisitos: Docker Desktop abierto · `gh` CLI (ya lo usáis) · ~2 h.

---

## Paso 0 — Instalar k6 (una vez)

```powershell
winget install k6 --source winget
k6 version   # debe responder
```

## Paso 1 — Crear el staging desechable (5 min)

1. [supabase.com/dashboard](https://supabase.com/dashboard) → **New project**:
   - Nombre: `taxicount-staging` · Región: la misma que prod (EU).
   - **Guarda la Database password** que elijas (la necesitas en el paso 3).
2. Espera ~2 min a que aprovisione.
3. Apunta 4 datos del proyecto staging:
   - **Settings → API**: `Project URL` (p. ej. `https://abcd1234.supabase.co`),
     **anon key** y **service_role key**.
   - Botón **Connect** → **Session pooler** URI (puerto 5432, host
     `aws-0-<region>.pooler.supabase.com`) → pon tu contraseña en la URI.

## Paso 2 — Configurar auth del staging (1 min, CRÍTICO)

**Authentication → Sign In / Providers → Email → desactiva "Confirm email"**.

> Sin esto, el `signup` del test no devuelve sesión y el setup falla a la
> primera. (En prod está activado; en el staging desechable no hace falta.)

## Paso 3 — Cargar esquema + datos reales (10 min)

Restauramos el **último backup de prod** (mismo mecanismo que el simulacro T7):
esquema completo + datos realistas, sin pelearse con 61 migraciones.

```powershell
cd C:\Users\Usuario\Documents\TaxiCount

# 3a. Descarga el último backup diario (artefacto de GitHub Actions)
$run = gh run list --workflow=backup-db.yml --status success --limit 1 --json databaseId -q '.[0].databaseId'
gh run download $run --dir backup-staging
Get-ChildItem backup-staging -Recurse -Filter *.dump   # apunta la ruta del .dump

# 3b. Restaura al staging (sustituye la URI del Session pooler y la ruta del dump)
docker run --rm -v "${PWD}:/b" --entrypoint pg_restore postgres:17 `
  --no-owner --no-privileges `
  -d "postgresql://postgres.abcd1234:TU_PASSWORD@aws-0-eu-west-1.pooler.supabase.com:5432/postgres" `
  "/b/backup-staging/db-backup-XX/taxicount_XXXX.dump"
```

Saldrán avisos (grants/roles): **normales**. Verifica en el SQL editor del staging:

```sql
select count(*) from public.tenants;   -- debe ser > 0
```

**3c. El trigger de alta (CRÍTICO).** El dump solo trae el esquema `public`;
el trigger que crea la empresa al registrarse vive en `auth.users` y hay que
recrearlo. En el **SQL editor del staging** pega:

```sql
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();
```

> Sin esto, el setup del k6 falla con `tenant_id = null`.

## Paso 4 — Backend local apuntando al staging (5 min)

En una **terminal aparte** (déjala abierta durante todo el test):

```powershell
cd C:\Users\Usuario\Documents\TaxiCount\backend
$env:SUPABASE_URL = "https://abcd1234.supabase.co"          # URL del staging
$env:SUPABASE_SERVICE_ROLE_KEY = "<service_role del staging>"
npm start
```

Verifica: `http://localhost:3000/health` → `status: ok`.

## Paso 5 — Ejecutar los 3 perfiles (~25 min)

En OTRA terminal, desde la raíz del repo. Primero las variables comunes:

```powershell
cd C:\Users\Usuario\Documents\TaxiCount
$env:BASE_URL    = "https://abcd1234.supabase.co"     # URL del staging
$env:ANON_KEY    = "<anon key del staging>"
$env:SERVICE_KEY = "<service_role del staging>"
$env:BACKEND_URL = "http://localhost:3000"
```

> ⚠️ **Sobre el escenario de login:** Supabase Cloud limita los inicios de
> sesión por IP (~30 cada 5 min). Por eso los perfiles usan `VUS_LOGIN` bajo y
> `POOL=25`; si ves 429 en `login`, es el límite de la plataforma, no vuestra
> app. La capacidad real la miden **insert** y **dashboard** (van contra la BD).

**Perfil 1 — 100 conductores** (~6 min):

```powershell
k6 run -e VUS_LOGIN=10 -e VUS_INSERT=100 -e VUS_DASH=10 -e VUS_EXPORT=3 `
       -e DUR_INSERT=5m -e POOL=25 tests/load/test_scenarios.js
```

**Perfil 2 — 500 conductores** (~6 min):

```powershell
k6 run -e VUS_LOGIN=15 -e VUS_INSERT=500 -e VUS_DASH=30 -e VUS_EXPORT=5 `
       -e DUR_INSERT=5m -e POOL=25 tests/load/test_scenarios.js
```

**Perfil 3 — 1000 conductores** (~8 min):

```powershell
k6 run -e VUS_LOGIN=20 -e VUS_INSERT=1000 -e VUS_DASH=60 -e VUS_EXPORT=8 `
       -e DUR_INSERT=5m -e POOL=25 tests/load/test_scenarios.js
```

**Durante el perfil 3**, ten abierto el staging → **Reports** (Database) y mira
CPU y conexiones en vivo.

## Paso 6 — Anotar resultados

De la salida de k6, la línea `http_req_duration` por escenario (p95) y
`http_req_failed` (% errores). Rellena:

| Fecha | Perfil | p95 login | p95 insert | p95 dashboard | p95 export | Errores % | CPU BD pico | Veredicto |
|---|---|---|---|---|---|---|---|---|
| — | 100 | — | — | — | — | — | — | — |
| — | 500 | — | — | — | — | — | — | — |
| — | 1000 | — | — | — | — | — | — | — |

**Umbrales de alarma:** login >500 ms · insert >800 ms · dashboard >1500 ms ·
export >10 s · errores >1% · CPU BD >70% sostenido.

**La frase final (el entregable del T8):**
> «Aguantamos ~___ conductores concurrentes; el primer límite es ___.»

⚠️ Matiz: el staging es Free tier (menos CPU que vuestro Pro de prod), así que
el resultado es un **suelo** — prod rendirá igual o mejor.

## Paso 7 — Limpieza (2 min)

1. Corta el backend local (Ctrl+C en su terminal).
2. Supabase → proyecto `taxicount-staging` → Settings → General → **Delete project**.
3. Borra la carpeta `backup-staging/` del repo (no la commitees).

## Si algo falla

| Síntoma | Causa | Arreglo |
|---|---|---|
| setup falla al primer paso (sin `access_token`) | "Confirm email" activado | Paso 2 |
| `tenant_id = null` en setup | falta el trigger | Paso 3c |
| 401 al crear drivers | service key equivocada en el backend local | Paso 4 |
| muchos 429 solo en `login` | rate limit de auth de Supabase (plataforma) | esperado; ignora login |
| ECONNREFUSED :3000 | backend local no corriendo | Paso 4 |
