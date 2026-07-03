-- ============================================================================
-- 056_vehicle_license_driver_read.sql
--
-- El CONDUCTOR debe poder VER el nº de licencia del taxi (no editarlo). Antes
-- vehicle_license() solo lo devolvía al owner. Ahora lo devuelve a cualquier
-- miembro del tenant (owner o conductor); la escritura (set_vehicle_license)
-- sigue siendo solo del owner. Idempotente.
-- ============================================================================
create or replace function public.vehicle_license(p_vehicle uuid)
returns text
language sql stable security definer
set search_path = public
as $$
  select vl.license_number
    from public.vehicle_licenses vl
   where vl.vehicle_id = p_vehicle
     and vl.tenant_id = public.current_tenant_id();
$$;
revoke all on function public.vehicle_license(uuid) from public, anon;
grant execute on function public.vehicle_license(uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
