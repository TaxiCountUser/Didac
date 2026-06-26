-- ============================================================
-- TaxiCount - El autónomo nace ya como conductor con nombre por defecto.
-- Al crear la empresa en modo autónomo, ponemos display_name = 'Yo mismo' para
-- que la vista Chófer le salude con un nombre (editable después por el usuario).
-- ============================================================
create or replace function public.create_solo_company(p_name text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_existing uuid;
  v_tenant   uuid;
begin
  if v_uid is null then raise exception 'No autenticado'; end if;
  select tenant_id into v_existing from public.users where id = v_uid;
  if v_existing is not null then raise exception 'Ya perteneces a una flota'; end if;

  insert into public.tenants (name, join_code, solo)
  values (
    coalesce(nullif(btrim(p_name), ''), 'Mi taxi'),
    upper(substr(md5(random()::text || v_uid::text || clock_timestamp()::text), 1, 6)),
    true
  )
  returning id into v_tenant;

  -- Es propietario y, a la vez, su propio conductor (display_name por defecto).
  update public.users
     set tenant_id = v_tenant,
         role = 'owner',
         active = true,
         display_name = coalesce(nullif(btrim(display_name), ''), 'Yo mismo')
   where id = v_uid;
  return v_tenant;
end;
$$;
grant execute on function public.create_solo_company(text) to authenticated;
