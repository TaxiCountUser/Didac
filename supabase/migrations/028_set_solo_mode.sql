-- ============================================================
-- TaxiCount - Activar/desactivar modo autónomo desde Ajustes.
-- Permite que un propietario marque su empresa como "solo" (él es a la vez
-- propietario y chófer) sin tener que crearla así desde el principio.
-- ============================================================
create or replace function public.set_solo_mode(p_solo boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_tenant uuid;
  v_role   text;
begin
  if v_uid is null then raise exception 'No autenticado'; end if;
  select tenant_id, role::text into v_tenant, v_role from public.users where id = v_uid;
  if v_tenant is null then raise exception 'No perteneces a ninguna empresa'; end if;
  if v_role <> 'owner' then raise exception 'Solo el propietario puede cambiar esto'; end if;
  update public.tenants set solo = coalesce(p_solo, false) where id = v_tenant;
  return true;
end;
$$;
grant execute on function public.set_solo_mode(boolean) to authenticated;
