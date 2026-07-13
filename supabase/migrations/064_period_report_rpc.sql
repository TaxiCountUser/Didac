-- ============================================================================
-- 064 — Agregación del cierre de jornada en la BD (Mes 3, M3-2)
--
-- `periodReport` (cierre de día/semana/mes/año) traía TODAS las transacciones del
-- rango al cliente para sumar ingresos/gasto/por-método y para calcular las horas
-- (primer/último instante de actividad por día). Esta RPC hace esa parte en
-- Postgres y devuelve:
--   - income, expense                     (SUM ... FILTER)
--   - income_by_method                    (GROUP BY payment_method, solo ingresos)
--   - tx_activity: [[first_at, last_at]]  (min/max de created_at por DÍA LOCAL)
-- La parte de km (lecturas de odómetro, con relleno retroactivo) y el cómputo
-- final de horas se mantienen en el cliente: pocas filas de odómetro y lógica
-- delicada que no conviene duplicar en SQL.
--
-- p_offset = offset local en minutos (DateTime.now().timeZoneOffset), para agrupar
-- por día natural local igual que el cliente. El cliente re-agrupa los first/last
-- devueltos por su propia hora local, así que un borde de DST no altera el
-- resultado (solo afecta a qué min/max se calcula, dentro del mismo día).
--
-- SECURITY INVOKER (por defecto): la RLS limita tenant + rol; filtro explícito
-- tenant_id = current_tenant_id() para que con service_role (RLS off) devuelva
-- vacío, no todo. Idempotente.
-- ============================================================================
create or replace function public.period_report(
  p_user   uuid        default null,
  p_from   timestamptz default null,
  p_to     timestamptz default null,
  p_offset int         default 0
)
returns jsonb
language sql
stable
set search_path = public
as $$
  with tx as (
    select amount, type, payment_method, created_at
    from public.transactions
    where tenant_id = public.current_tenant_id()
      and (p_user is null or user_id = p_user)
      and (p_from is null or created_at >= p_from)
      and (p_to   is null or created_at <  p_to)
  ),
  days as (
    select
      ((created_at at time zone 'UTC') + make_interval(mins => p_offset))::date as d,
      min(created_at) as first_at,
      max(created_at) as last_at
    from tx
    group by 1
  )
  select jsonb_build_object(
    'income',  coalesce((select sum(amount) from tx where type = 'income'),  0),
    'expense', coalesce((select sum(amount) from tx where type = 'expense'), 0),
    'income_by_method', coalesce((
      select jsonb_object_agg(m, s)
      from (
        select coalesce(nullif(payment_method, ''), 'otros') as m, sum(amount) as s
        from tx
        where type = 'income'
        group by 1
      ) g
    ), '{}'::jsonb),
    'tx_activity', coalesce((
      select jsonb_agg(jsonb_build_array(first_at, last_at))
      from days
    ), '[]'::jsonb)
  );
$$;

revoke all on function public.period_report(uuid, timestamptz, timestamptz, int) from public, anon;
grant execute on function public.period_report(uuid, timestamptz, timestamptz, int) to authenticated, service_role;

notify pgrst, 'reload schema';
