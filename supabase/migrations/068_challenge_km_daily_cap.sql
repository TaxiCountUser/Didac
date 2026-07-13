-- ============================================================================
-- 068 — Blindaje del km/día: descarta saltos absurdos (datos erróneos)
--
-- challenge_km_daily calcula km/día como el incremento del odómetro entre días
-- por vehículo. Una lectura mal introducida (p. ej. 324.423 km de golpe) o un
-- odómetro en una carrera con un valor disparatado produce un delta absurdo que
-- domina el gráfico. Un taxi no recorre >2.000 km en un día: los deltas fuera de
-- [0, p_cap] se tratan como error de datos y se EXCLUYEN (cuentan 0), en vez de
-- inflar la serie.
--
-- Además se aplica el cap ANTES de sumar, por (vehículo, día). create or replace.
-- ============================================================================
-- Se elimina la firma anterior (solo p_days) para no dejar una sobrecarga que
-- haría ambigua la llamada en PostgREST.
drop function if exists public.challenge_km_daily(int);

create or replace function public.challenge_km_daily(p_days int default 30, p_cap numeric default 2000)
returns table(day date, km numeric)
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
  with odo as (
    select vehicle_id, reading_km::numeric as km, taken_at::date as d
      from public.odometer_readings
     where vehicle_id is not null
    union all
    select vehicle_id, odometer_km::numeric as km, created_at::date as d
      from public.transactions
     where odometer_km is not null and vehicle_id is not null
  ),
  daily_max as (
    select vehicle_id, d, max(km) as km
      from odo group by vehicle_id, d
  ),
  deltas as (
    select d, km - lag(km) over (partition by vehicle_id order by d) as delta
      from daily_max
  )
  select d as day,
         coalesce(sum(case when delta >= 0 and delta <= p_cap then delta else 0 end), 0) as km
    from deltas
   where d >= (current_date - make_interval(days => greatest(p_days, 1) - 1))::date
   group by d
   order by d;
$$;

revoke all on function public.challenge_km_daily(int, numeric) from public, anon, authenticated;
grant execute on function public.challenge_km_daily(int, numeric) to service_role;

notify pgrst, 'reload schema';
