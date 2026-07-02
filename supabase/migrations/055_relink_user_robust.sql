-- ============================================================================
-- 055_relink_user_robust.sql   (corrige 054)
--
-- La 054 re-vinculaba el perfil huérfano cambiando su id (update id). Eso FALLA
-- si el usuario tiene filas en tablas cuyo FK a users.id no tiene ON UPDATE
-- CASCADE (p. ej. challenge_claims), y el login volvía a dar "Database error
-- saving new user".
--
-- Esta versión, cuando ya existe un perfil con ese email (auth borrado ->
-- huérfano), lo BORRA y crea uno nuevo vinculado al nuevo id, PRESERVANDO
-- is_admin. El borrado cae en cascada / pone a null (según cada FK), así que no
-- depende de ON UPDATE CASCADE. Idempotente.
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

notify pgrst, 'reload schema';
