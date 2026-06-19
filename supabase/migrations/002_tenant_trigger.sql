-- ============================================================
-- TaxiCount - Fase 1
-- Tarea 2: creación automática de tenant + perfil al registrarse.
-- Tarea 8: campo de onboarding.
--
-- Al insertarse un usuario en auth.users:
--   - Si el metadata trae tenant_id  -> es un DRIVER invitado a un
--     tenant existente (lo crea el Owner vía service_role).
--   - Si NO trae tenant_id           -> es un OWNER nuevo: se crea un
--     tenant y su perfil con rol 'owner'.
-- ============================================================

-- Columnas nuevas en el perfil de usuario
alter table public.users add column if not exists name text;
alter table public.users add column if not exists has_completed_onboarding boolean not null default false;

-- Función del trigger (SECURITY DEFINER -> corre como owner, omite RLS)
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
    -- Driver invitado a un tenant existente
    v_tenant_id := (v_meta ->> 'tenant_id')::uuid;
    v_role := coalesce(nullif(v_meta ->> 'role', ''), 'driver')::user_role;
  else
    -- Owner nuevo: crear su tenant
    v_role := 'owner';
    insert into public.tenants (name)
    values (coalesce(nullif(v_meta ->> 'company_name', ''), split_part(NEW.email, '@', 1)))
    returning id into v_tenant_id;
  end if;

  insert into public.users (id, tenant_id, email, name, role)
  values (NEW.id, v_tenant_id, NEW.email, nullif(v_meta ->> 'name', ''), v_role)
  on conflict (id) do nothing;

  return NEW;
end;
$$;

-- (Re)crear el trigger en auth.users
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();
