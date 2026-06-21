#!/usr/bin/env bash
# ============================================================
# TaxiCount - Fase 6: descarga un backup lógico de la BD de
# producción/staging (Supabase) y lo restaura en el entorno LOCAL.
#
# NO restaura sobre producción. El destino por defecto es el Postgres
# local de docker-compose.
#
# Requisitos: pg_dump / psql (cliente de Postgres 15) y acceso de red.
#
# Uso:
#   SOURCE_DB_URL="postgresql://postgres:PASS@db.<ref>.supabase.co:5432/postgres" \
#     ./scripts/restore-backup.sh
#
# Variables:
#   SOURCE_DB_URL   Cadena de conexión de ORIGEN (Supabase). Obligatoria.
#   TARGET_DB_URL   Destino (def. local docker). NUNCA apuntar a producción.
#   OUT_DIR         Carpeta de dumps (def. ./backups).
# ============================================================
set -euo pipefail

SOURCE_DB_URL="${SOURCE_DB_URL:-}"
TARGET_DB_URL="${TARGET_DB_URL:-postgresql://postgres:postgres@localhost:5432/postgres}"
OUT_DIR="${OUT_DIR:-./backups}"
STAMP="$(date +%Y%m%d_%H%M%S)"
DUMP_FILE="${OUT_DIR}/taxicount_${STAMP}.dump"

if [ -z "$SOURCE_DB_URL" ]; then
  echo "ERROR: define SOURCE_DB_URL (cadena de conexión de Supabase)." >&2
  exit 1
fi

# Salvaguarda: el destino no puede ser un host de supabase.co
case "$TARGET_DB_URL" in
  *supabase.co*|*supabase.com*)
    echo "ERROR: TARGET_DB_URL apunta a un host de Supabase. Abortado por seguridad." >&2
    exit 1
    ;;
esac

mkdir -p "$OUT_DIR"

echo "[1/3] Descargando backup de ORIGEN -> ${DUMP_FILE}"
# Formato custom (-Fc): comprimido y restaurable selectivamente.
# Solo el esquema public (datos de la app); auth/storage los gestiona Supabase.
pg_dump "$SOURCE_DB_URL" -Fc --no-owner --no-privileges \
  --schema=public --file "$DUMP_FILE"

echo "[2/3] Restaurando en DESTINO (local): ${TARGET_DB_URL%%@*}@..."
# --clean --if-exists: reemplaza objetos existentes de public sin fallar.
pg_restore --clean --if-exists --no-owner --no-privileges \
  --schema=public --dbname "$TARGET_DB_URL" "$DUMP_FILE"

echo "[3/3] Verificación rápida (conteos):"
psql "$TARGET_DB_URL" -c \
  "select 'tenants' t, count(*) from public.tenants
   union all select 'users', count(*) from public.users
   union all select 'transactions', count(*) from public.transactions;"

echo "OK. Backup en ${DUMP_FILE} y restaurado en el destino local."
