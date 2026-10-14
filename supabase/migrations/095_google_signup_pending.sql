-- ============================================================================
-- 095 — Alta con Google: vuelve a quedar PENDIENTE (sin empresa) para que la app
-- le pregunte qué quiere hacer (empresa / autónomo / unirse a una flota).
--
-- Regresión desde el 2026-07-02: la 054/055 reescribieron handle_new_auth_user
-- para re-vincular cuentas huérfanas y PERDIERON el caso de la 023 "alta por
-- OAuth sin datos -> pendiente". Desde entonces TODA alta con Google creaba una
-- empresa con el nombre del correo y saltaba la pantalla de elegir (choose_path),
-- y esas empresas se creaban SIN join_code (sus conductores no podían unirse).
--
-- Esta versión = 055 (re-vinculación de huérfanos, conserva is_admin) + las tres
-- ramas de la 023: conductor invitado (tenant_id en metadata) / alta explícita de
-- empresa (company_name, con join_code) / resto (Google) -> pendiente.
-- Además rellena el join_code de las empresas que se quedaron sin él.
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
    -- Conductor invitado a una empresa existente (lo crea el jefe vía service_role).
    v_tenant_id := (v_meta ->> 'tenant_id')::uuid;
    v_role := coalesce(nullif(v_meta ->> 'role', ''), 'driver')::user_role;
    insert into public.users (id, tenant_id, email, name, role)
    values (NEW.id, v_tenant_id, NEW.email, nullif(v_meta ->> 'name', ''), v_role)
    on conflict (id) do nothing;

  elsif nullif(v_meta ->> 'company_name', '') is not null then
    -- Alta explícita de empresa (registro por correo con nombre de empresa).
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
    -- Alta con Google (sin datos): PENDIENTE, sin empresa. La app le pregunta si
    -- crea empresa, es autónomo o se une a una flota con un código.
    insert into public.users (id, tenant_id, email, name, role)
    values (NEW.id, null, NEW.email, nullif(coalesce(v_meta ->> 'full_name', v_meta ->> 'name'), ''), 'driver')
    on conflict (id) do nothing;
  end if;

  return NEW;
end;
$$;

-- Empresas que se quedaron sin código de invitación (creadas por la 055).
update public.tenants
   set join_code = upper(substr(md5(random()::text || id::text || clock_timestamp()::text), 1, 6))
 where join_code is null and closed_at is null;

notify pgrst, 'reload schema';
