-- ============================================================================
-- 067 — Evolución diaria de km recorridos (visión global de retos en el admin)
--
-- El dashboard de retos del admin muestra CUÁNDO se completan los logros, pero
-- no cómo AVANZAN los conductores día a día. Esta RPC devuelve los km recorridos
-- por día (globales, todos los conductores) para pintar la evolución junto a los
-- retos completados y ver "cómo van" antes de asolirlos.
--
-- Km/día = suma, por vehículo, del incremento del odómetro entre el día y su
-- lectura anterior (delta positivo). El lag se calcula sobre TODO el historial
-- (no solo la ventana) para no atribuir todo el recorrido previo al primer día
-- visible. Solo se emiten los días dentro de la ventana p_days.
--
-- SECURITY DEFINER + solo service_role (lo llama el backend en /admin/*).
-- Fechas en UTC (::date) para alinear con el gráfico de "completados por día".
-- create or replace, idempotente.
-- ============================================================================
create or replace function public.challenge_km_daily(p_days int default 30)
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
    -- Lectura máxima del odómetro por (vehículo, día).
    select vehicle_id, d, max(km) as km
      from odo group by vehicle_id, d
  ),
  deltas as (
    select d,
           greatest(0, km - lag(km) over (partition by vehicle_id order by d)) as km
      from daily_max
  )
  select d as day, coalesce(sum(km), 0) as km
    from deltas
   where d >= (current_date - make_interval(days => greatest(p_days, 1) - 1))::date
   group by d
   order by d;
$$;

revoke all on function public.challenge_km_daily(int) from public, anon, authenticated;
grant execute on function public.challenge_km_daily(int) to service_role;

notify pgrst, 'reload schema';
