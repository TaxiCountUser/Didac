-- ============================================================================
-- 054_relink_user_on_reauth.sql
--
-- PROBLEMA: public.users.id NO referencia a auth.users y public.users.email es
-- UNIQUE. Si se borra la cuenta auth de alguien (p. ej. al cerrar su empresa),
-- su fila de public.users queda HUÉRFANA con ese email. Al volver a entrar
-- (Google/Add user), auth crea un id nuevo y el trigger intenta insertar una
-- fila con el mismo email -> viola el unique(email) -> "Database error saving
-- new user" y el login falla.
--
-- SOLUCIÓN: el trigger, si ya existe una fila con ese email, la RE-VINCULA al
-- nuevo id (update id; cascada por ON UPDATE CASCADE) preservando rol, is_admin,
-- tenant, etc. Así volver a loguearse recupera el perfil (incluido el admin) sin
-- intervención manual. Idempotente.
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
begin
  v_meta := coalesce(NEW.raw_user_meta_data, '{}'::jsonb);

  -- Re-vincular perfil existente por email (auth recreado): preserva is_admin,
  -- rol y tenant. Evita el fallo por unique(email). ON UPDATE CASCADE arrastra
  -- las referencias (carreras, lecturas, tokens...).
  if exists (select 1 from public.users where lower(email) = lower(NEW.email)) then
    update public.users set id = NEW.id where lower(email) = lower(NEW.email);
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
