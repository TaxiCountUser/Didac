-- ============================================================
-- TaxiCount - Prueba de 15 días + modo autónomo + admin global.
--
-- 1) Prueba gratis de 15 días: cada tenant nuevo puede usar la app 15 días sin
--    tarjeta. Al caducar, si no hay suscripción activa, la escritura se bloquea
--    (las políticas RLS ya exigen current_subscription_active()).
-- 2) Modo autónomo (solo=true): el dueño es también su propio chófer; sin GPS y
--    solo plan Starter. A nivel de datos sigue siendo un 'owner' (ya puede crear
--    sus propias transacciones), la app le ofrece un conmutador Empresa/Chófer.
-- 3) Admin global (is_admin): ve y resuelve incidencias de TODAS las empresas.
--    El acceso real va por el backend con service_role; aquí solo guardamos la
--    marca y sembramos al admin principal.
-- ============================================================

-- ---------- 1) Prueba de 15 días ----------
alter table public.tenants
  add column if not exists trial_ends_at timestamptz;

-- Tenants existentes: 15 días desde su creación (los muy antiguos quedarán ya
-- caducados, lo cual es correcto: deben suscribirse).
update public.tenants
   set trial_ends_at = created_at + interval '15 days'
 where trial_ends_at is null;

-- A partir de ahora, por defecto 15 días desde el alta.
alter table public.tenants
  alter column trial_ends_at set default (now() + interval '15 days');

-- La suscripción "permite escribir" si está activa/al día, o si sigue dentro de
-- la prueba de 15 días.
create or replace function public.current_subscription_active()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select coalesce(
    (select
        subscription_status in ('active', 'past_due')  -- 'past_due' = margen de cortesía
        or (subscription_status = 'trialing' and now() < coalesce(trial_ends_at, now()))
        or now() < coalesce(trial_ends_at, 'epoch'::timestamptz)
       from public.tenants
      where id = public.current_tenant_id()),
    false)
$$;

grant execute on function public.current_subscription_active() to anon, authenticated, service_role;

-- ---------- 2) Modo autónomo ----------
alter table public.tenants
  add column if not exists solo boolean not null default false;

-- RPC: crear mi empresa en modo autónomo (soy empresa y chófer a la vez).
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

  update public.users
     set tenant_id = v_tenant, role = 'owner', active = true
   where id = v_uid;
  return v_tenant;
end;
$$;

grant execute on function public.create_solo_company(text) to authenticated;

-- ---------- 3) Admin global ----------
alter table public.users
  add column if not exists is_admin boolean not null default false;

-- Admin principal de la plataforma.
update public.users set is_admin = true where lower(email) = 'didakdp.5@gmail.com';

-- Helper: ¿el usuario autenticado es admin de plataforma? (SECURITY DEFINER
-- para no chocar con RLS). Se usa para endurecer/relajar políticas si hiciera
-- falta; el panel admin real va por el backend con service_role.
create or replace function public.is_platform_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select coalesce((select is_admin from public.users where id = auth.uid()), false)
$$;

grant execute on function public.is_platform_admin() to anon, authenticated, service_role;
