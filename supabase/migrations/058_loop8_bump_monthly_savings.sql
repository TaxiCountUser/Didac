-- ============================================================================
-- 058_loop8_bump_monthly_savings.sql   (Loop #8 · Iteración 2)
--
-- Incremento atómico de los contadores de ahorro del mes (tenant/año/mes).
-- Lo llama el backend (service_role) al aplicar cada extensión de recompensa.
-- Idempotente en el sentido de "crear o sumar": crea la fila del mes si no
-- existe y suma el delta si ya existe.
-- ============================================================================
create or replace function public.bump_monthly_savings(
  p_tenant     uuid,
  p_year       int,
  p_month      int,
  p_challenges numeric,
  p_referrals  numeric
) returns void
language sql
security definer
set search_path = public
as $$
  insert into public.monthly_savings(
      tenant_id, year, month, savings_from_challenges, savings_from_referrals, calculated_at)
  values (p_tenant, p_year, p_month, coalesce(p_challenges, 0), coalesce(p_referrals, 0), now())
  on conflict (tenant_id, year, month) do update
    set savings_from_challenges = public.monthly_savings.savings_from_challenges + coalesce(excluded.savings_from_challenges, 0),
        savings_from_referrals  = public.monthly_savings.savings_from_referrals  + coalesce(excluded.savings_from_referrals, 0),
        calculated_at = now();
$$;
revoke all on function public.bump_monthly_savings(uuid, int, int, numeric, numeric) from public, anon, authenticated;
grant execute on function public.bump_monthly_savings(uuid, int, int, numeric, numeric) to service_role;

notify pgrst, 'reload schema';
