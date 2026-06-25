-- ============================================================
-- TaxiCount - El Owner puede editar el NOMBRE de un conductor de su flota.
-- Vía RPC SECURITY DEFINER (comprueba que es owner del mismo tenant).
-- El correo de acceso NO se cambia aquí (es de auth; requiere admin API).
-- ============================================================
create or replace function public.owner_set_driver_name(p_driver uuid, p_name text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.current_role_name() <> 'owner' then
    raise exception 'Solo el owner puede editar conductores';
  end if;
  update public.users
     set name = nullif(btrim(p_name), '')
   where id = p_driver
     and tenant_id = public.current_tenant_id()
     and role = 'driver';
end;
$$;
grant execute on function public.owner_set_driver_name(uuid, text) to authenticated;
