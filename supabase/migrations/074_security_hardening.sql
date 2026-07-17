-- ============================================================================
-- 074_security_hardening.sql  (auditoría de seguridad)
--
-- (1) Contador de transcripción ATÓMICO: el backend hacía read-check-write en
--     dos pasos (TOCTOU) y peticiones concurrentes podían saltarse el tope
--     diario. Se sustituye por una función que comprueba e incrementa en UNA
--     sentencia (UPDATE con guardia en el WHERE). Solo la usa el backend
--     (service_role).
--
-- (2) system_config deja de exponer a anon/authenticated las claves internas
--     (flags de plataforma, cron_last_*, svc_*, active_coupon). El cliente NO lee
--     esta tabla directamente (va por el backend), así que solo se deja leer
--     la config PÚBLICA del programa de referidos. Todo lo demás: service_role.
-- ============================================================================

-- (1) Incremento atómico del contador diario de transcripción.
create or replace function public.bump_daily_transcription(p_user uuid, p_limit int)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_allowed boolean;
begin
  update public.users
     set daily_transcription_count = case
           when transcription_count_date is distinct from current_date then 1
           else coalesce(daily_transcription_count, 0) + 1
         end,
         transcription_count_date = current_date
   where id = p_user
     and (transcription_count_date is distinct from current_date
          or coalesce(daily_transcription_count, 0) < p_limit)
   returning true into v_allowed;
  return coalesce(v_allowed, false);
end;
$$;

revoke all on function public.bump_daily_transcription(uuid, int) from public, anon, authenticated;
grant execute on function public.bump_daily_transcription(uuid, int) to service_role;

-- (2) Restringir la lectura directa de system_config.
drop policy if exists system_config_read on public.system_config;

-- anon (web pública / login): solo la config del programa de referidos.
create policy system_config_read_anon on public.system_config
  for select to anon
  using (left(key, 9) = 'referral_');

-- authenticated: referidos + retos (por si alguna pantalla los lee directo).
-- NO ve flags de plataforma, cron_last_*, svc_* ni active_coupon (esos van por
-- el backend, que usa service_role y no pasa por RLS).
create policy system_config_read_auth on public.system_config
  for select to authenticated
  using (left(key, 9) = 'referral_' or left(key, 10) = 'challenge_');

notify pgrst, 'reload schema';
