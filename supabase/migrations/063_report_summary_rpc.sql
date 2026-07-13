-- ============================================================================
-- 063 — Agregación del dashboard en la BD (Mes 3, M3-1)
--
-- El resumen del dashboard (KPIs del Owner y del conductor) se calculaba trayendo
-- TODAS las transacciones del rango al cliente y sumando en el navegador: a un
-- mes/año de una flota grande son miles de filas por cada refresco de panel (el
-- primer límite que midió el load test T8). Esta RPC lo agrega en Postgres con
-- SUM ... FILTER + GROUP BY y devuelve un JSON pequeño.
--
-- SECURITY INVOKER (por defecto): la RLS de `transactions` ya limita por tenant y
-- rol (owner ve todo el tenant; conductor solo lo suyo), así que agregar como el
-- llamante es seguro — pasar `p_user` de otro conductor no revela nada porque la
-- RLS filtra igualmente. Sin riesgo de escalada.
-- Idempotente.
-- ============================================================================
create or replace function public.report_summary(
  p_user    uuid        default null,
  p_vehicle uuid        default null,
  p_from    timestamptz default null,
  p_to      timestamptz default null,
  p_client  text        default null
)
returns jsonb
language sql
stable
set search_path = public
as $$
  with f as (
    select amount, type, category
    from public.transactions
    where tenant_id = public.current_tenant_id()  -- explícito: con service_role
                                                  -- (RLS off) devuelve vacío, no todo
      and (p_user    is null or user_id    = p_user)
      and (p_vehicle is null or vehicle_id = p_vehicle)
      and (p_from    is null or created_at >= p_from)
      and (p_to      is null or created_at <  p_to)
      and (p_client  is null or p_client = '' or client_name ilike '%' || p_client || '%')
    -- La RLS añade además el filtro por rol (owner: todo el tenant; conductor: lo suyo).
  )
  select jsonb_build_object(
    'income',  coalesce(sum(amount) filter (where type = 'income'),  0),
    'expense', coalesce(sum(amount) filter (where type = 'expense'), 0),
    'expense_by_category', coalesce((
      select jsonb_object_agg(cat, s)
      from (
        select coalesce(nullif(category, ''), 'otros') as cat, sum(amount) as s
        from f
        where type = 'expense'
        group by 1
      ) g
    ), '{}'::jsonb)
  )
  from f;
$$;

revoke all on function public.report_summary(uuid, uuid, timestamptz, timestamptz, text) from public, anon;
grant execute on function public.report_summary(uuid, uuid, timestamptz, timestamptz, text) to authenticated, service_role;

notify pgrst, 'reload schema';
