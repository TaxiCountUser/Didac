-- ============================================================================
-- 048_loop6_challenge_km_from_initial_odometer.sql  (Loop #6 · Iteración 2)
--
-- El reto de 100.000 km pasa a medir los km RECORRIDOS POR EL VEHÍCULO desde su
-- initial_odometer (km al alta, mig. 045), en vez de desde registered_km / la
-- primera lectura. Base por (conductor, vehículo):
--   km = max(0, ultima_lectura - base)  con base = initial_odometer si > 0,
--        si no registered_km, si no la primera lectura (compat. datos antiguos).
--
-- Solo cambia el cálculo del km; el resto (dinero, días, anti-fraude) intacto.
-- create or replace, idempotente.
-- ============================================================================

create or replace function public.challenge_stats_tenant(p_tenant uuid)
returns table(
  user_id uuid, name text, email text,
  km numeric, money numeric, active_days int, max_jump numeric, max_income numeric
)
language sql stable security definer
set search_path = public
as $$
  with odo as (
    select user_id, vehicle_id, reading_km::numeric as km, taken_at::date as d
      from public.odometer_readings where tenant_id = p_tenant
    union all
    select user_id, vehicle_id, odometer_km::numeric as km, created_at::date as d
      from public.transactions
     where tenant_id = p_tenant and odometer_km is not null and vehicle_id is not null
  ),
  km_per_user as (
    select t.user_id,
           coalesce(sum(greatest(0,
             t.mx - case when v.initial_odometer > 0 then v.initial_odometer
                         else coalesce(v.registered_km, t.mn) end
           )), 0) as km
      from (
        select user_id, vehicle_id, max(km) as mx, min(km) as mn
          from odo group by user_id, vehicle_id
      ) t
      left join public.vehicles v on v.id = t.vehicle_id
     group by t.user_id
  ),
  jumps as (
    select user_id, coalesce(max(km - prev), 0) as max_jump from (
      select user_id, km,
             lag(km) over (partition by user_id, vehicle_id order by km) as prev
        from odo
    ) z where prev is not null group by user_id
  ),
  money_per_user as (
    select user_id, coalesce(sum(case when type = 'income' then amount else -amount end), 0) as money
      from public.transactions where tenant_id = p_tenant group by user_id
  ),
  income_per_user as (
    select user_id, coalesce(max(amount), 0) as max_income
      from public.transactions where tenant_id = p_tenant and type = 'income' group by user_id
  ),
  days_per_user as (
    select user_id, count(distinct d) as active_days from (
      select user_id, created_at::date as d from public.transactions where tenant_id = p_tenant
      union
      select user_id, taken_at::date as d from public.odometer_readings where tenant_id = p_tenant
      union
      select user_id, day as d from public.app_usage_days where tenant_id = p_tenant
    ) x group by user_id
  )
  select u.id, u.name, u.email,
         coalesce(k.km, 0), coalesce(m.money, 0),
         coalesce(d.active_days, 0)::int, coalesce(j.max_jump, 0), coalesce(i.max_income, 0)
    from public.users u
    left join km_per_user k     on k.user_id = u.id
    left join money_per_user m  on m.user_id = u.id
    left join income_per_user i on i.user_id = u.id
    left join days_per_user d   on d.user_id = u.id
    left join jumps j           on j.user_id = u.id
   where u.tenant_id = p_tenant and u.active is not false
   order by coalesce(k.km, 0) desc;
$$;
grant execute on function public.challenge_stats_tenant(uuid) to service_role;

-- Versión por conductor (no la usa hoy el backend, pero se deja coherente).
create or replace function public.challenge_stats(p_user uuid)
returns table(km numeric, money numeric, active_days int)
language sql stable security definer
set search_path = public
as $$
  with odo as (
    select vehicle_id, reading_km::numeric as km, taken_at::date as d
      from public.odometer_readings where user_id = p_user
    union all
    select vehicle_id, odometer_km::numeric as km, created_at::date as d
      from public.transactions
     where user_id = p_user and odometer_km is not null and vehicle_id is not null
  ),
  per_vehicle as (
    select coalesce(sum(greatest(0,
             t.max_km - case when v.initial_odometer > 0 then v.initial_odometer
                             else coalesce(v.registered_km, t.min_km) end
           )), 0) as km_total
      from (select vehicle_id, max(km) as max_km, min(km) as min_km
              from odo group by vehicle_id) t
      left join public.vehicles v on v.id = t.vehicle_id
  ),
  bal as (
    select coalesce(sum(case when type = 'income' then amount else -amount end), 0) as money
      from public.transactions where user_id = p_user
  ),
  days as (
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

notify pgrst, 'reload schema';
