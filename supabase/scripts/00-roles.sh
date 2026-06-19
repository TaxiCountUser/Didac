#!/bin/bash
# Se ejecuta en el PRIMER arranque de la DB (/docker-entrypoint-initdb.d).
# Fija la contraseña de los roles de sistema de Supabase para que
# GoTrue (supabase_auth_admin) y PostgREST (authenticator) puedan conectar.
set -e

PW="${POSTGRES_PASSWORD:-postgres}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  -- Crear roles si no existieran (la imagen supabase/postgres ya los trae)
  DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='supabase_auth_admin') THEN
      CREATE ROLE supabase_auth_admin LOGIN NOINHERIT CREATEROLE;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='authenticator') THEN
      CREATE ROLE authenticator LOGIN NOINHERIT;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='anon') THEN
      CREATE ROLE anon NOLOGIN NOINHERIT;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='authenticated') THEN
      CREATE ROLE authenticated NOLOGIN NOINHERIT;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='service_role') THEN
      CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
    END IF;
  END \$\$;

  -- Contraseñas de los roles que hacen LOGIN
  ALTER ROLE supabase_auth_admin WITH LOGIN PASSWORD '${PW}';
  ALTER ROLE authenticator       WITH LOGIN PASSWORD '${PW}';

  -- authenticator debe poder cambiar a los roles de PostgREST
  GRANT anon, authenticated, service_role TO authenticator;

  -- Esquema de auth (GoTrue migrará dentro). Lo creamos por si la imagen no lo trae.
  CREATE SCHEMA IF NOT EXISTS auth AUTHORIZATION supabase_auth_admin;
  GRANT ALL PRIVILEGES ON SCHEMA auth TO supabase_auth_admin;
  ALTER ROLE supabase_auth_admin SET search_path = auth;
EOSQL

echo "[00-roles] Roles de sistema configurados."
