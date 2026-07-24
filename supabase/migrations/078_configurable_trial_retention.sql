-- 078_configurable_trial_retention.sql
-- Hace configurables desde el panel (Config): la DURACIÓN DE PRUEBA por defecto de
-- los nuevos tenants y la VENTANA DE RETENCIÓN RGPD de la purga. Antes eran valores
-- fijos (default de columna 15 días, e interval '5 years' en la función de purga).
--
-- IMPORTANTE: NO se toca el trigger handle_new_auth_user (crítico para el alta). En su
-- lugar, el DEFAULT de la columna trial_ends_at pasa a leer la config. Las funciones
-- lectoras SANITIZAN el valor y tienen fallback, así que un valor inválido en config
-- NUNCA rompe el alta de usuarios ni la purga.

-- 1) Semillas de config (no pisar si ya existen).
insert into public.system_config (key, value)
values ('default_trial_days', '15'), ('retention_years', '5')
on conflict (key) do nothing;

-- 2) Días de prueba por defecto: lee config, saca solo dígitos, fallback 15, clamp 1..90.
--    stable + security definer (bypassa RLS de system_config). Nunca lanza excepción.
create or replace function public.default_trial_days()
returns int
language sql
stable
security definer
set search_path = public
as $$
  select greatest(1, least(90, coalesce(
    nullif(regexp_replace(coalesce((select value from public.system_config where key = 'default_trial_days'), ''), '\D', '', 'g'), '')::int,
    15)));
$$;

-- 3) El DEFAULT de trial_ends_at pasa a usar la config (sin tocar el trigger de alta).
alter table public.tenants
  alter column trial_ends_at set default (now() + (public.default_trial_days() || ' days')::interval);

-- 4) Purga de retención: la ventana pasa a leerse de config (fallback 5, clamp 1..10 años).
create or replace function public.purge_expired_retention()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
  v_years int;
begin
  v_years := greatest(1, least(10, coalesce(
    nullif(regexp_replace(coalesce((select value from public.system_config where key = 'retention_years'), ''), '\D', '', 'g'), '')::int,
    5)));
  delete from public.tenants
   where closed_at is not null
     and closed_at < now() - (v_years || ' years')::interval;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- La purga sigue siendo solo para service_role (como antes).
revoke all on function public.purge_expired_retention() from public, anon, authenticated;
grant execute on function public.purge_expired_retention() to service_role;

notify pgrst, 'reload schema';
