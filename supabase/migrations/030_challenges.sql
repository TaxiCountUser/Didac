-- ============================================================
-- TaxiCount - Retos / metas por conductor.
--
-- Dos retos, medidos POR CONDUCTOR:
--   km_100k     -> 100.000 km acumulados en sus coches.
--   money_100k  -> 100.000 € de balance (ingresos - gastos).
-- Ambos exigen un mínimo de 300 días activos (días distintos con actividad).
-- Si se alcanzan antes de 300 días, se marca como SOSPECHOSO para revisión.
--
-- Premio: un mes gratis para el DUEÑO de la suscripción (la empresa que paga).
-- Entrega: NO automática. Se crea un "claim" pendiente; el admin lo revisa y
-- aprueba (o rechaza) desde su panel. La aprobación extiende trial_ends_at +30d.
--
-- El cálculo del progreso se hace en challenge_stats(); el backend (service_role)
-- crea los claims al detectar que se cruza el umbral.
-- ============================================================

-- 1) Claims de retos: una fila por (conductor, reto). Idempotente.
create table if not exists public.challenge_claims (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  user_id      uuid not null references public.users(id)   on delete cascade,
  challenge    text not null check (challenge in ('km_100k', 'money_100k')),
  metric_value numeric not null default 0,   -- valor alcanzado al registrarlo
  active_days  int     not null default 0,   -- días activos al registrarlo
  status       text    not null default 'pending'
               check (status in ('pending', 'rewarded', 'rejected')),
  created_at   timestamptz not null default now(),
  reviewed_at  timestamptz
);
create unique index if not exists challenge_claims_user_chal_uidx
  on public.challenge_claims(user_id, challenge);
create index if not exists challenge_claims_tenant_idx on public.challenge_claims(tenant_id);

grant select, insert, update, delete on public.challenge_claims to authenticated, service_role;
alter table public.challenge_claims enable row level security;

-- El conductor ve sus propios claims; el owner ve los de su empresa.
drop policy if exists challenge_claims_select on public.challenge_claims;
create policy challenge_claims_select on public.challenge_claims
  for select to authenticated
  using (
    user_id = auth.uid()
    or (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner')
  );

-- 2) Cálculo del progreso de un conductor (km, dinero, días activos).
--    SECURITY DEFINER para sortear RLS de forma controlada; el acceso real lo
--    decide quién la llama (el backend con service_role, o el wrapper de abajo).
create or replace function public.challenge_stats(p_user uuid)
returns table(km numeric, money numeric, active_days int)
language sql stable security definer
set search_path = public
as $$
  with odo as (
    -- Lecturas de cuentakilómetros del conductor (de readings y de carreras).
    select vehicle_id, reading_km::numeric as km, taken_at::date as d
      from public.odometer_readings where user_id = p_user
    union all
    select vehicle_id, odometer_km::numeric as km, created_at::date as d
      from public.transactions
     where user_id = p_user and odometer_km is not null and vehicle_id is not null
  ),
  per_vehicle as (
    -- Km acumulados por coche = máximo - mínimo registrado por el conductor.
    select coalesce(sum(max_km - min_km), 0) as km_total
      from (select vehicle_id, max(km) as max_km, min(km) as min_km
              from odo group by vehicle_id) t
  ),
  bal as (
    select coalesce(sum(case when type = 'income' then amount else -amount end), 0) as money
      from public.transactions where user_id = p_user
  ),
  days as (
    -- Días distintos con actividad (transacciones o lecturas de km).
    select count(distinct d) as n from (
      select created_at::date as d from public.transactions where user_id = p_user
      union
      select taken_at::date as d from public.odometer_readings where user_id = p_user
    ) x
  )
  select (select km_total from per_vehicle),
         (select money from bal),
         (select n from days)::int;
$$;

grant execute on function public.challenge_stats(uuid) to service_role;

-- Wrapper para que el propio conductor consulte SOLO sus stats desde la app.
create or replace function public.my_challenge_stats()
returns table(km numeric, money numeric, active_days int)
language sql stable security definer
set search_path = public
as $$
  select * from public.challenge_stats(auth.uid());
$$;
grant execute on function public.my_challenge_stats() to authenticated;
