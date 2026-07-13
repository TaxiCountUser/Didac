-- ============================================================================
-- 065 — Rollups diarios del dashboard (Mes 3, M3-3/M3-4)
--
-- Pre-agrega por (tenant, conductor, día local) los totales que el dashboard
-- consulta: income, expense, tx_count, ingresos por método, gasto por categoría,
-- y primer/último instante de actividad (para las horas). Así un resumen de
-- mes/año suma ~30-365 filas de rollup por conductor en vez de miles de tx.
--
-- Se mantiene EXACTO de forma incremental: un trigger sobre `transactions`
-- RECALCULA el bucket (tenant,user,día) afectado en cada insert/update/delete
-- (recompute completo del día → sin drift ante ediciones/borrados). El día es el
-- día natural LOCAL (report_tz(), 'Europe/Madrid') para casar con los rangos que
-- pasa el cliente (medianoche local). Backfill al final para los datos actuales.
--
-- Las RPCs de lectura (report_summary_rollup / period_report_rollup) devuelven el
-- MISMO shape que las de 063/064; el cliente las usa para rangos grandes sin
-- filtro por vehículo/cliente, con fallback a las RPCs crudas (exactas). RLS
-- aísla por tenant/rol igual que `transactions`.
-- ============================================================================

-- Zona horaria de referencia para el día natural de los informes. Centralizada
-- para poder cambiarla o hacerla por-tenant en el futuro sin tocar el resto.
create or replace function public.report_tz()
returns text
language sql immutable
set search_path = public
as $$ select 'Europe/Madrid'::text $$;

-- ---------------------------------------------------------------------------
-- Tabla de rollups
-- ---------------------------------------------------------------------------
create table if not exists public.tenant_daily_rollup (
  tenant_id           uuid not null references public.tenants(id) on delete cascade,
  user_id             uuid not null references public.users(id)   on delete cascade,
  day                 date not null,                 -- día natural LOCAL (report_tz)
  income              numeric(14,2) not null default 0,
  expense             numeric(14,2) not null default 0,
  tx_count            integer       not null default 0,
  income_by_method    jsonb         not null default '{}'::jsonb,
  expense_by_category jsonb         not null default '{}'::jsonb,
  first_at            timestamptz,                   -- primera/última actividad del día
  last_at             timestamptz,
  primary key (tenant_id, user_id, day)
);

create index if not exists idx_rollup_tenant_day on public.tenant_daily_rollup (tenant_id, day);

alter table public.tenant_daily_rollup enable row level security;
-- Lectura como en transactions: owner ve su tenant, conductor solo lo suyo.
drop policy if exists rollup_select on public.tenant_daily_rollup;
create policy rollup_select on public.tenant_daily_rollup
  for select to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (public.current_role_name() = 'owner' or user_id = auth.uid())
  );
-- Escritura SOLO por el trigger (security definer) y service_role. Sin políticas
-- de insert/update/delete para authenticated.
grant select on public.tenant_daily_rollup to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Recompute de un bucket (tenant, user, día local) desde las tx de ese día.
-- Acota por rango de created_at (índice user+created) para no escanear todo el
-- histórico del conductor en cada insert.
-- ---------------------------------------------------------------------------
create or replace function public.refresh_tenant_daily_rollup(p_tenant uuid, p_user uuid, p_day date)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start timestamptz := (p_day::timestamp)               at time zone public.report_tz();
  v_end   timestamptz := ((p_day + 1)::timestamp)         at time zone public.report_tz();
  v_income numeric; v_expense numeric; v_cnt int;
  v_first timestamptz; v_last timestamptz;
  v_ibm jsonb; v_ebc jsonb;
begin
  select
    coalesce(sum(amount) filter (where type = 'income'),  0),
    coalesce(sum(amount) filter (where type = 'expense'), 0),
    count(*), min(created_at), max(created_at)
  into v_income, v_expense, v_cnt, v_first, v_last
  from public.transactions
  where tenant_id = p_tenant and user_id = p_user
    and created_at >= v_start and created_at < v_end;

  if v_cnt = 0 then
    delete from public.tenant_daily_rollup
      where tenant_id = p_tenant and user_id = p_user and day = p_day;
    return;
  end if;

  select coalesce(jsonb_object_agg(m, s), '{}'::jsonb) into v_ibm from (
    select coalesce(nullif(payment_method, ''), 'otros') as m, sum(amount) as s
    from public.transactions
    where tenant_id = p_tenant and user_id = p_user
      and created_at >= v_start and created_at < v_end and type = 'income'
    group by 1
  ) x;

  select coalesce(jsonb_object_agg(c, s), '{}'::jsonb) into v_ebc from (
    select coalesce(nullif(category, ''), 'otros') as c, sum(amount) as s
    from public.transactions
    where tenant_id = p_tenant and user_id = p_user
      and created_at >= v_start and created_at < v_end and type = 'expense'
    group by 1
  ) x;

  insert into public.tenant_daily_rollup
    (tenant_id, user_id, day, income, expense, tx_count, income_by_method, expense_by_category, first_at, last_at)
  values (p_tenant, p_user, p_day, v_income, v_expense, v_cnt, v_ibm, v_ebc, v_first, v_last)
  on conflict (tenant_id, user_id, day) do update set
    income = excluded.income, expense = excluded.expense, tx_count = excluded.tx_count,
    income_by_method = excluded.income_by_method, expense_by_category = excluded.expense_by_category,
    first_at = excluded.first_at, last_at = excluded.last_at;
end;
$$;

-- ---------------------------------------------------------------------------
-- Trigger de mantenimiento incremental
-- ---------------------------------------------------------------------------
create or replace function public.trg_tx_rollup()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if TG_OP = 'DELETE' then
    perform public.refresh_tenant_daily_rollup(
      OLD.tenant_id, OLD.user_id, (OLD.created_at at time zone public.report_tz())::date);
    return OLD;
  end if;

  perform public.refresh_tenant_daily_rollup(
    NEW.tenant_id, NEW.user_id, (NEW.created_at at time zone public.report_tz())::date);

  -- UPDATE que mueve la fila de bucket: refresca también el bucket antiguo.
  if TG_OP = 'UPDATE' and (
       OLD.tenant_id is distinct from NEW.tenant_id
    or OLD.user_id  is distinct from NEW.user_id
    or (OLD.created_at at time zone public.report_tz())::date
         is distinct from (NEW.created_at at time zone public.report_tz())::date
  ) then
    perform public.refresh_tenant_daily_rollup(
      OLD.tenant_id, OLD.user_id, (OLD.created_at at time zone public.report_tz())::date);
  end if;
  return NEW;
end;
$$;

drop trigger if exists tx_rollup_aiud on public.transactions;
create trigger tx_rollup_aiud
  after insert or update or delete on public.transactions
  for each row execute function public.trg_tx_rollup();

-- ---------------------------------------------------------------------------
-- RPCs de lectura sobre rollups (mismo shape que 063/064)
-- ---------------------------------------------------------------------------
create or replace function public.report_summary_rollup(
  p_user uuid        default null,
  p_from timestamptz default null,
  p_to   timestamptz default null
)
returns jsonb
language sql
stable
set search_path = public
as $$
  with r as (
    select income, expense, expense_by_category
    from public.tenant_daily_rollup
    where tenant_id = public.current_tenant_id()
      and (p_user is null or user_id = p_user)
      and (p_from is null or day >= (p_from at time zone public.report_tz())::date)
      and (p_to   is null or day <  (p_to   at time zone public.report_tz())::date)
  )
  select jsonb_build_object(
    'income',  coalesce((select sum(income)  from r), 0),
    'expense', coalesce((select sum(expense) from r), 0),
    'expense_by_category', coalesce((
      select jsonb_object_agg(k, s)
      from (
        select kv.key as k, sum(kv.value::numeric) as s
        from r, lateral jsonb_each_text(r.expense_by_category) as kv
        group by kv.key
      ) g
    ), '{}'::jsonb)
  );
$$;

revoke all on function public.report_summary_rollup(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.report_summary_rollup(uuid, timestamptz, timestamptz) to authenticated, service_role;

create or replace function public.period_report_rollup(
  p_user uuid        default null,
  p_from timestamptz default null,
  p_to   timestamptz default null
)
returns jsonb
language sql
stable
set search_path = public
as $$
  with r as (
    select income, expense, income_by_method, first_at, last_at
    from public.tenant_daily_rollup
    where tenant_id = public.current_tenant_id()
      and (p_user is null or user_id = p_user)
      and (p_from is null or day >= (p_from at time zone public.report_tz())::date)
      and (p_to   is null or day <  (p_to   at time zone public.report_tz())::date)
  )
  select jsonb_build_object(
    'income',  coalesce((select sum(income)  from r), 0),
    'expense', coalesce((select sum(expense) from r), 0),
    'income_by_method', coalesce((
      select jsonb_object_agg(k, s)
      from (
        select kv.key as k, sum(kv.value::numeric) as s
        from r, lateral jsonb_each_text(r.income_by_method) as kv
        group by kv.key
      ) g
    ), '{}'::jsonb),
    'tx_activity', coalesce((
      select jsonb_agg(jsonb_build_array(first_at, last_at))
      from r
      where first_at is not null
    ), '[]'::jsonb)
  );
$$;

revoke all on function public.period_report_rollup(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.period_report_rollup(uuid, timestamptz, timestamptz) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Backfill de los datos existentes (reusa el recompute → exacto).
-- ---------------------------------------------------------------------------
do $$
declare rec record;
begin
  for rec in
    select distinct tenant_id, user_id,
           (created_at at time zone public.report_tz())::date as day
    from public.transactions
  loop
    perform public.refresh_tenant_daily_rollup(rec.tenant_id, rec.user_id, rec.day);
  end loop;
end;
$$;

notify pgrst, 'reload schema';
