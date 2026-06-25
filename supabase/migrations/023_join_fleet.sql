-- ============================================================
-- TaxiCount - Alta diferida + unirse a una flota con código.
--
-- Antes: cualquier alta por OAuth (Google) sin metadata se convertía en un
-- Owner con empresa vacía. Ahora queda PENDIENTE (sin flota) y la app le ofrece
-- elegir: crear su empresa (propietario) o unirse a una flota con un código que
-- el jefe comparte. Los conductores que el jefe da de alta por correo siguen
-- vinculándose solos (su identidad de Google enlaza a su cuenta confirmada).
-- ============================================================

-- 1) tenant_id pasa a ser OPCIONAL: un usuario recién creado sin flota queda
--    "pendiente" hasta que elige crear empresa o unirse a una.
alter table public.users alter column tenant_id drop not null;

-- 2) Código de flota: corto y único; el jefe lo comparte con sus trabajadores.
alter table public.tenants add column if not exists join_code text;
update public.tenants
   set join_code = upper(substr(md5(random()::text || id::text || clock_timestamp()::text), 1, 6))
 where join_code is null;
create unique index if not exists tenants_join_code_uidx on public.tenants(join_code);

-- 3) Trigger de alta: OAuth/sin metadata => usuario SIN flota (pendiente).
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
begin
  v_meta := coalesce(NEW.raw_user_meta_data, '{}'::jsonb);

  if (v_meta ? 'tenant_id') and nullif(v_meta ->> 'tenant_id', '') is not null then
    -- Driver invitado a un tenant existente (lo crea el Owner vía service_role).
    v_tenant_id := (v_meta ->> 'tenant_id')::uuid;
    v_role := coalesce(nullif(v_meta ->> 'role', ''), 'driver')::user_role;
    insert into public.users (id, tenant_id, email, name, role)
    values (NEW.id, v_tenant_id, NEW.email, nullif(v_meta ->> 'name', ''), v_role)
    on conflict (id) do nothing;

  elsif nullif(v_meta ->> 'company_name', '') is not null then
    -- Alta explícita de Owner (registro con nombre de empresa): crea su tenant.
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
    -- Alta por OAuth (Google) sin datos: PENDIENTE, sin flota. La app le pedirá
    -- crear empresa o unirse a una con un código.
    insert into public.users (id, tenant_id, email, name, role)
    values (NEW.id, null, NEW.email, null, 'driver')
    on conflict (id) do nothing;
  end if;

  return NEW;
end;
$$;

-- 4) RPC: crear mi empresa (para un usuario pendiente -> pasa a Owner).
create or replace function public.create_owner_company(p_name text)
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

  insert into public.tenants (name, join_code)
  values (
    coalesce(nullif(btrim(p_name), ''), 'Mi empresa'),
    upper(substr(md5(random()::text || v_uid::text || clock_timestamp()::text), 1, 6))
  )
  returning id into v_tenant;

  update public.users
     set tenant_id = v_tenant, role = 'owner', active = true
   where id = v_uid;
  return v_tenant;
end;
$$;

-- 5) RPC: unirse a una flota con código (para un usuario pendiente -> Driver).
create or replace function public.join_fleet_with_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_existing uuid;
  v_tenant   uuid;
  v_name     text;
  v_limit    int;
  v_count    int;
begin
  if v_uid is null then raise exception 'No autenticado'; end if;
  select tenant_id into v_existing from public.users where id = v_uid;
  if v_existing is not null then raise exception 'Ya perteneces a una flota'; end if;

  select id, name, drivers_limit
    into v_tenant, v_name, v_limit
    from public.tenants
   where upper(join_code) = upper(btrim(p_code));
  if v_tenant is null then raise exception 'Código no válido'; end if;

  if v_limit is not null then
    select count(*) into v_count
      from public.users where tenant_id = v_tenant and role = 'driver';
    if v_count >= v_limit then
      raise exception 'La flota ha alcanzado su límite de conductores';
    end if;
  end if;

  update public.users
     set tenant_id = v_tenant, role = 'driver', active = true
   where id = v_uid;
  return jsonb_build_object('tenant_id', v_tenant, 'name', v_name);
end;
$$;

grant execute on function public.create_owner_company(text) to authenticated;
grant execute on function public.join_fleet_with_code(text) to authenticated;
