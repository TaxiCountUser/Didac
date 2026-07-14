-- ============================================================================
-- 070 — Estadísticas de BD ampliadas para el panel de Monitorización
--
-- Añade más métricas de la base de datos a db_resource_stats(): ratio de acierto
-- de caché, transacciones (commits/rollbacks), tuplas leídas/escritas, queries
-- activas y en espera (locks), y la conexión más antigua. Todo desde las vistas
-- pg_stat_*. SECURITY DEFINER, solo backend (service_role). Idempotente.
-- ============================================================================
create or replace function public.db_resource_stats()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
  with db as (
    select * from pg_stat_database where datname = current_database()
  )
  select jsonb_build_object(
    'db_size_bytes',      pg_database_size(current_database()),
    'db_size_pretty',     pg_size_pretty(pg_database_size(current_database())),
    'connections',        (select count(*) from pg_stat_activity),
    'connections_active', (select count(*) from pg_stat_activity where state = 'active'),
    'connections_idle',   (select count(*) from pg_stat_activity where state = 'idle'),
    'connections_waiting',(select count(*) from pg_stat_activity where wait_event_type = 'Lock'),
    'max_connections',    (select setting::int from pg_settings where name = 'max_connections'),
    -- Ratio de acierto de caché (%): lecturas servidas desde memoria vs disco.
    'cache_hit_ratio',    (select case when (blks_hit + blks_read) > 0
                             then round(100.0 * blks_hit / (blks_hit + blks_read), 1)
                             else null end from db),
    'commits',            (select xact_commit from db),
    'rollbacks',          (select xact_rollback from db),
    'tuples_returned',    (select tup_returned from db),
    'tuples_fetched',     (select tup_fetched from db),
    'tuples_inserted',    (select tup_inserted from db),
    'tuples_updated',     (select tup_updated from db),
    'tuples_deleted',     (select tup_deleted from db),
    'deadlocks',          (select deadlocks from db),
    'temp_bytes',         (select temp_bytes from db),
    -- Segundos de la transacción activa más antigua (posibles queries colgadas).
    'oldest_txn_secs',    (select coalesce(round(extract(epoch from (now() - min(xact_start))))::int, 0)
                             from pg_stat_activity where state <> 'idle' and xact_start is not null),
    'at', now()
  );
$$;

revoke all on function public.db_resource_stats() from public, anon, authenticated;
grant execute on function public.db_resource_stats() to service_role;

notify pgrst, 'reload schema';
