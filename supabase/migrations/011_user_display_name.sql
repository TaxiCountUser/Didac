-- ============================================================
-- TaxiCount - Nombre "de avatar" del conductor.
--
-- `name` lo pone el jefe (lo ve en SU panel y no cambia). `display_name` es
-- opcional y lo elige el propio conductor para mostrarse en SU app. Si está
-- vacío, la app del conductor usa `name`.
-- ============================================================

alter table public.users
  add column if not exists display_name text;
