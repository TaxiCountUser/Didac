-- ============================================================================
-- 096 — TODA alta nueva (Google o correo) queda PENDIENTE (sin empresa): la app
-- le pregunta qué quiere hacer (empresa / autónomo / unirse a una flota) en
-- ChoosePathScreen, que es donde se pide el nombre y se crea la empresa
-- (RPC create_owner_company / create_solo_company / join_fleet_with_code).
--
-- Antes (095) una alta por correo con `company_name` seguía creando empresa
-- automáticamente y saltándose esa pantalla. Ahora `company_name` se IGNORA
-- (las apps antiguas lo siguen mandando): solo crea empresa si además llega
-- `create_company: true`, que únicamente usan los tests de integración.
-- Se mantienen: re-vinculación de cuentas huérfanas (055) y conductores
-- invitados por su jefe (tenant_id en metadata, lo pone el backend).
-- ============================================================================
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_meta      jsonb;
  v_tenant_id uuid;
  v_role      user_role;
  v_admin     boolean;
begin
  v_meta := coalesce(NEW.raw_user_meta_data, '{}'::jsonb);

  -- Perfil existente con ese email (su cuenta auth fue borrada): reemplazar por
  -- uno nuevo vinculado al nuevo id, conservando is_admin. Queda sin empresa.
  select is_admin into v_admin from public.users where lower(email) = lower(NEW.email);
  if found then
    delete from public.users where lower(email) = lower(NEW.email);
    insert into public.users (id, tenant_id, email, name, role, is_admin)
    values (NEW.id, null, NEW.email, nullif(v_meta ->> 'name', ''),
            case when coalesce(v_admin, false) then 'owner'::user_role else 'driver'::user_role end,
            coalesce(v_admin, false));
    return NEW;
  end if;

  if (v_meta ? 'tenant_id') and nullif(v_meta ->> 'tenant_id', '') is not null then
    -- Conductor (o titular reactivado) creado por el backend en una empresa existente.
    v_tenant_id := (v_meta ->> 'tenant_id')::uuid;
    v_role := coalesce(nullif(v_meta ->> 'role', ''), 'driver')::user_role;
    insert into public.users (id, tenant_id, email, name, role)
    values (NEW.id, v_tenant_id, NEW.email, nullif(v_meta ->> 'name', ''), v_role)
    on conflict (id) do nothing;

  elsif (v_meta ->> 'create_company') = 'true' and nullif(v_meta ->> 'company_name', '') is not null then
    -- Solo tests de integración: alta con empresa directa.
    insert into public.tenants (name, join_code)
    values (
      v_meta ->> 'company_name',
      upper(substr(md5(random()::text || NEW.id::text || clock_timestamp()::text), 1, 6))
    )
    returning id into v_tenant_id;
    insert into public.users (id, tenant_id, email, name, role)
    values (NEW.id, v_tenant_id, NEW.email, nullif(v_meta ->> 'name', ''), 'owner')
    on conflict (id) do nothing;

  else
    -- Alta normal (Google o correo): PENDIENTE, sin empresa -> pantalla de elegir.
    insert into public.users (id, tenant_id, email, name, role)
    values (NEW.id, null, NEW.email, nullif(coalesce(v_meta ->> 'full_name', v_meta ->> 'name'), ''), 'driver')
    on conflict (id) do nothing;
  end if;

  return NEW;
end;
$$;

notify pgrst, 'reload schema';
