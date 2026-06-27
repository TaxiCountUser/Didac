# ============================================================
# TaxiCount - Backup rapido de la BD de produccion (Supabase) a un
# archivo en TU PC. No instala nada: usa pg_dump si lo tienes, y si no,
# lo ejecuta a traves de Docker (imagen oficial de Postgres).
#
# La cadena de conexion (con tu contrasena) se escribe SOLO en tu PC y
# nunca se guarda en disco ni se sube a ningun sitio.
#
# Uso:
#   ./scripts/backup-db.ps1
#   ./scripts/backup-db.ps1 -ConnString "postgresql://postgres:PASS@db.xxx.supabase.co:5432/postgres"
#
# Resultado: un archivo en .\backups\taxicount_<fecha>.dump
# ============================================================
param(
  [string]$ConnString = "",
  [string]$OutDir = "backups"
)

$ErrorActionPreference = "Stop"

# --- 1) Cadena de conexion (param, env, o se pide aqui) ---
if (-not $ConnString) { $ConnString = $env:SUPABASE_DB_URL }
if (-not $ConnString) {
  Write-Host "Pega tu cadena de conexion de Supabase"
  Write-Host "(Project Settings -> Database -> Connection string -> URI):" -ForegroundColor Cyan
  $ConnString = Read-Host "Conexion"
}
if (-not $ConnString) { Write-Error "No se proporciono cadena de conexion."; exit 1 }

# Aviso si apunta al pooler (puerto 6543): para dumps usa el directo (5432).
if ($ConnString -match ":6543") {
  Write-Warning "Estas usando el pooler (6543). Para backups es mejor el puerto directo 5432."
}

# --- 2) Preparar carpeta y nombre con fecha ---
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd_HHmm"
$dumpFile = Join-Path $OutDir "taxicount_$stamp.dump"

# Argumentos de pg_dump: formato custom (-Fc, comprimido y restaurable
# selectivamente), solo esquema public (los datos de la app; auth/storage
# los gestiona Supabase). --no-owner/--no-privileges para que restaure limpio.
$pgArgs = @("-Fc","--no-owner","--no-privileges","--schema=public")

Write-Host "Creando backup -> $dumpFile" -ForegroundColor Green

# --- 3a) pg_dump local si existe ---
$pgDump = Get-Command pg_dump -ErrorAction SilentlyContinue
if ($pgDump) {
  & $pgDump.Source $ConnString @pgArgs --file $dumpFile
  if ($LASTEXITCODE -ne 0) { Write-Error "pg_dump fallo (codigo $LASTEXITCODE)."; exit 1 }
}
else {
  # --- 3b) Via Docker (sin instalar nada) ---
  $docker = Get-Command docker -ErrorAction SilentlyContinue
  if (-not $docker) {
    Write-Error "No hay pg_dump ni Docker. Instala Docker Desktop o el cliente de PostgreSQL."
    exit 1
  }
  Write-Host "pg_dump no encontrado; usando Docker (postgres:16)..." -ForegroundColor Yellow
  $abs = (Resolve-Path $OutDir).Path
  # Montamos la carpeta de salida y volcamos dentro del contenedor.
  & docker run --rm -e PGCONN="$ConnString" -v "${abs}:/out" postgres:16 `
      sh -c "pg_dump `"`$PGCONN`" -Fc --no-owner --no-privileges --schema=public --file /out/taxicount_$stamp.dump"
  if ($LASTEXITCODE -ne 0) { Write-Error "El backup via Docker fallo (codigo $LASTEXITCODE)."; exit 1 }
}

# --- 4) Confirmacion ---
$size = (Get-Item $dumpFile).Length
$kb = [math]::Round($size / 1KB, 1)
Write-Host ""
Write-Host "OK. Backup creado: $dumpFile ($kb KB)" -ForegroundColor Green
Write-Host "Guardalo en sitio seguro. Para restaurarlo/probarlo: ver docs/backup-rapido.md" -ForegroundColor Gray
