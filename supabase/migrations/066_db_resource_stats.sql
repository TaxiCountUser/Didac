-- ============================================================================
-- 066 — Estadísticas de recursos de la BD para el panel de admin (monitor Supabase)
--
-- Devuelve tamaño de la BD y conexiones (uso vs. máximo), que el backend expone
-- en /admin/metrics junto al scrape del endpoint de métricas del proyecto. Solo
-- la llama el backend con service_role. SECURITY DEFINER para poder leer las
-- vistas del sistema (pg_stat_activity, settings). Idempotente.
-- ============================================================================
create or replace function public.db_resource_stats()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
  select jsonb_build_object(
    'db_size_bytes',   pg_database_size(current_database()),
    'db_size_pretty',  pg_size_pretty(pg_database_size(current_database())),
    'connections',     (select count(*) from pg_stat_activity),
    'connections_active', (select count(*) from pg_stat_activity where state = 'active'),
    'max_connections', (select setting::int from pg_settings where name = 'max_connections'),
    'at', now()
  );
$$;

revoke all on function public.db_resource_stats() from public, anon, authenticated;
grant execute on function public.db_resource_stats() to service_role;

notify pgrst, 'reload schema';
