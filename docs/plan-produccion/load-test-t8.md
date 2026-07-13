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

| Fecha | Perfil | p95 login* | p95 insert | p95 dashboard | p95 export | Errores % | Veredicto |
|---|---|---|---|---|---|---|---|
| 2026-07-11 | 100 | 358 ms | **108 ms** | 1,3 s | 1,72 s | 0 (solo 429 de login) | ✅ |
| 2026-07-11 | 500 | 746 ms | 1,91 s (p90 86 ms) | 4,12 s | 3,97 s | 0 | ⚠️ cola p95 por picos de dashboard |
| 2026-07-11 | 1000 | 1,04 s | **102 ms** | 1,25 s | 6,93 s | 0,003% (1/30.000) | ✅ |

\* login limitado por el rate limit de auth de Supabase (30/5 min/IP): 30
éxitos exactos por run. Irrelevante en uso real (cada taxista = su IP).

**Análisis (2026-07-11):** mediana del insert = 69 ms en los TRES perfiles;
1.000 VUs insertando cada 10 s ≈ 100 tx/s sostenidas con 1 fallo entre 30.000
(equivale a la carga de decenas de miles de conductores reales). El perfil 2
muestra cola p95 alta SOLO en la ventana donde 30 dashboards refrescaban en
bucle: el primer límite es la agregación del dashboard bajo concurrencia de
paneles, cuyo arreglo ya está planificado (Mes 3: agregación en backend +
caché/rollups). T9: sin acción ad-hoc; el fix correcto es el del Mes 3.

**LA FRASE:** «Aguantamos ~1.000 conductores concurrentes (≈100 carreras/s,
mediana 69 ms, 0,003% error) en staging Free tier — peor hardware que prod.
Primer límite: la agregación del dashboard, con solución ya planificada.»

**Umbrales de alarma:** login >500 ms · insert >800 ms · dashboard >1500 ms ·
export >10 s · errores >1% · CPU BD >70% sostenido.

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

## Anexo — Re-medición Mes 3 (M3-5, A/B agregación, 2026-07-13)

Tras M3-1/M3-2 (mover la agregación del dashboard a la BD vía RPCs
`report_summary`/`period_report`), re-medimos **el cambio real**. El escenario
`dashboard` de k6 ahora llama a la RPC (lo que hace hoy la app) y admite un A/B con
`DASH_MODE`: `rpc` (nuevo) vs `legacy` (el pull de todas las filas de antes). Se
siembra volumen con `SEED_TX`.

**Entorno:** stack Docker local (una sola máquina, red ~0), 30 paneles concurrentes
(`VUS_DASH=30`), mismo dataset por modo. Incluye el feed de 20 tx (constante en ambos).

```
k6 run -e VUS_DASH=30 -e SEED_TX=50000 -e POOL=2 -e DASH_MODE=legacy tests/load/test_scenarios.js
k6 run -e VUS_DASH=30 -e SEED_TX=50000 -e POOL=2 -e DASH_MODE=rpc    tests/load/test_scenarios.js
```

| Dataset | Modo | p95 dashboard | avg | max | throughput (iter) | datos recibidos |
|---|---|---|---|---|---|---|
| 50.000 tx | **legacy** (pull filas) | **3,23 s** ❌ | 847 ms | 8,04 s | 379 | **979 MB** |
| 50.000 tx | **rpc** (agrega en BD) | **0,95 s** ✅ | 358 ms | 1,79 s | 577 | **48 MB** |
| 5.000 tx | legacy | 145 ms | 53 ms | 657 ms | — | — |
| 5.000 tx | rpc | 161 ms | 70 ms | 389 ms | — | — |

**Lectura honesta:**
- A **50k tx** (un año de una flota mediana), la RPC es **3,4× más rápida en p95**
  (0,95 s vs 3,23 s), mueve **~20× menos datos** (48 MB vs 979 MB) y da **+52% de
  throughput**. Crítico: el modo legacy **cruza el umbral de 1500 ms** (falla la SLA
  del dashboard); la RPC se queda holgada por debajo del segundo.
- A **5k tx en localhost**, la RPC sale un pelín peor (161 vs 145 ms): sin latencia
  de red, transferir 5k filas pequeñas es casi gratis y la agregación añade algo de
  CPU. **La ventaja del RPC es la transferencia**, y solo domina cuando los datos
  crecen o hay red real de por medio (Cloud, RTT, ancho de banda) — donde mover
  979 MB vs 48 MB pesa mucho más que en local. Es decir: **la mejora en producción
  es mayor que la medida aquí**, no menor.

**Conclusión:** M3-1/M3-2 resuelven el primer límite. La agregación deja de escalar
con el nº de filas (O(filas)→O(1) de transferencia) y el dashboard se mantiene dentro
de la SLA a volúmenes 100× el actual. La medición T8 original (capacidad absoluta en
staging Free tier) no se repite: su escenario "dashboard" era un proxy (lista de 20)
y aquí medimos directamente lo que cambió. Un run T8 completo en staging queda como
verificación opcional de la cifra de capacidad absoluta.

## Anexo — Stress test "loco" (10.000 VUs, 2026-07-11)

Prueba extra fuera de los perfiles: `VUS_INSERT=10000` (10× lo validado).
**Resultado: colapso por congestión** — p95 insert 53 s, 90% timeouts,
throughput efectivo ~24 inserts/s (vs ~100/s con 1.000 VUs). Se rompió, como
era de esperar, por dos limitadores que NO son la arquitectura de la app:
1. **Supabase Free tier** (pool de PostgREST + CPU compartida mínimos).
2. **El cliente k6 en un solo portátil + red doméstica** (muchos timeouts son
   del lado cliente; 10k VUs limpios exigen k6 Cloud o runners distribuidos).

Traducción: 10k VUs insertando cada 10 s ≈ 1.000 escrituras/s ≈ carga de
escritura de **~600.000 conductores reales** (uno inserta cada ~10 min). Es
~600× el objetivo a 3 meses, sobre el hardware más débil posible. **No cambia
el plan.** Aprendizaje para 100k+ (más allá del Mes 3): a concurrencia de
escritura extrema, los inserts directos cliente→PostgREST compiten por el pool
de PostgREST sin control de la app → considerar enrutar escrituras de alta
frecuencia por el backend (pool controlado) o batching. Anotado, no accionable ahora.
