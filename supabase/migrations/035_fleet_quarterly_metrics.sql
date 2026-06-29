-- ============================================================================
-- 035_fleet_quarterly_metrics.sql
-- Loop #4 — Refactor de recompensas de gamificación (retos épicos).
--
-- Cambia el modelo de recompensa de "1 mes gratis al JEFE por cada conductor
-- que completa un ciclo" (insostenible: 100 conductores = 8 años gratis) a un
-- modelo TRIMESTRAL basado en el % de flota activa que ha logrado >=1 ciclo.
--
-- Esta migración SOLO crea estructura nueva (tablas + índices + RLS). No toca
-- ni borra datos existentes (challenge_claims se conserva para auditoría).
-- Bajo riesgo, idempotente.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) Métricas trimestrales por tenant (una fila por tenant+año+trimestre).
-- ---------------------------------------------------------------------------
create table if not exists public.fleet_quarterly_metrics (
  id                        uuid primary key default gen_random_uuid(),
  tenant_id                 uuid not null references public.tenants(id) on delete cascade,
  year                      int  not null,
  quarter                   int  not null check (quarter between 1 and 4),
  active_drivers            int  not null default 0,   -- conductores con km en últimos 30 días
  drivers_with_achievement  int  not null default 0,   -- de los activos, los que cerraron >=1 ciclo en el trimestre
  completion_rate           numeric(5,2) not null default 0,  -- 0.00 .. 100.00
  reward_days_awarded       int  not null default 0,   -- 0 / 7 / 15 / 30
  processed_at              timestamptz not null default now(),
  unique (tenant_id, year, quarter)
);

create index if not exists idx_fleet_quarterly_tenant
  on public.fleet_quarterly_metrics(tenant_id, year desc, quarter desc);

grant select on public.fleet_quarterly_metrics to authenticated;
grant select, insert, update, delete on public.fleet_quarterly_metrics to service_role;

alter table public.fleet_quarterly_metrics enable row level security;

-- Solo el JEFE (owner) ve las métricas de SU empresa; el admin de plataforma ve todas.
-- El cron escribe con service_role (que ignora RLS), así que no hay política de insert/update
-- para 'authenticated' a propósito (los clientes nunca escriben aquí).
drop policy if exists fleet_quarterly_select on public.fleet_quarterly_metrics;
create policy fleet_quarterly_select on public.fleet_quarterly_metrics
  for select to authenticated
  using (
    public.is_platform_admin()
    or (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner')
  );

-- ---------------------------------------------------------------------------
-- 2) Log de auditoría de ejecuciones del cron trimestral.
--    Útil para depurar y para no re-procesar un trimestre ya cerrado.
-- ---------------------------------------------------------------------------
create table if not exists public.cron_execution_logs (
  id                 uuid primary key default gen_random_uuid(),
  job_name           text not null,                 -- p.ej. 'fleet_quarterly_rewards'
  period_label       text,                          -- p.ej. '2026-Q2'
  started_at         timestamptz not null default now(),
  finished_at        timestamptz,
  status             text not null default 'running' check (status in ('running','success','error')),
  tenants_processed  int  not null default 0,
  rewards_granted    int  not null default 0,
  details            jsonb,                          -- resumen libre (por tenant, etc.)
  error              text
);

create index if not exists idx_cron_logs_job_started
  on public.cron_execution_logs(job_name, started_at desc);

grant select on public.cron_execution_logs to authenticated;
grant select, insert, update, delete on public.cron_execution_logs to service_role;

alter table public.cron_execution_logs enable row level security;

-- Solo el admin de plataforma puede consultar los logs del cron.
drop policy if exists cron_logs_select on public.cron_execution_logs;
create policy cron_logs_select on public.cron_execution_logs
  for select to authenticated
  using (public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- 3) challenge_claims: el campo `level` ya existe (migración 030), no se toca.
--    La tabla se MANTIENE para auditoría del progreso individual; la lógica de
--    aprobación manual se desactiva en el backend (Iteración 4), no aquí.
-- ---------------------------------------------------------------------------
