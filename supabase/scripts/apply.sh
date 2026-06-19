#!/usr/bin/env bash
# Aplica migraciones y seed contra la base de datos local.
# Se ejecuta una vez (servicio db-init) cuando db + auth están sanos.
set -euo pipefail

HOST="db"
PORT="5432"
USER="postgres"
DB="postgres"
export PGPASSWORD="${PGPASSWORD:-postgres}"

echo "[db-init] Esperando a que el esquema 'auth' exista (GoTrue migrado)..."
for i in $(seq 1 60); do
  exists=$(psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -tAc \
    "select count(*) from information_schema.tables where table_schema='auth' and table_name='users';" || echo 0)
  if [ "$exists" = "1" ]; then
    echo "[db-init] Esquema auth listo."
    break
  fi
  echo "[db-init] auth.users aún no existe (intento $i)..."
  sleep 2
done

echo "[db-init] Aplicando migraciones..."
for f in $(ls -1 /migrations/*.sql | sort); do
  echo "[db-init]  -> $f"
  psql -v ON_ERROR_STOP=1 -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -f "$f"
done

echo "[db-init] Aplicando seed..."
psql -v ON_ERROR_STOP=1 -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -f /seed.sql

echo "[db-init] Recargando la caché de esquema de PostgREST..."
psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -c "NOTIFY pgrst, 'reload schema';"

echo "[db-init] Migraciones + seed aplicadas correctamente."
