-- ============================================================
-- TaxiCount - 094: REGISTRO DE JORNADA, fase 2.
--
-- 1) Correcciones del JEFE (o autónomo) con MOTIVO obligatorio:
--    * workday_correct: cambia la hora (y/o los km) de una pulsación. La primera
--      vez guarda el valor original (original_at / original_km); siempre deja
--      quién, cuándo y por qué (corrected_by / corrected_at / correction_reason).
--      El orden se respeta: no puede quedar antes de la pulsación anterior ni
--      después de la siguiente, ni en el futuro.
--    * workday_close: cierra una jornada que el conductor se dejó abierta, a la
--      hora que diga el jefe, con motivo (queda marcada como corregida).
--    Tras cada cambio se recalcula la jornada (started_at/ended_at/km).
-- 2) Avisos push (backend workday_reminders.js), una vez cada uno:
--    * work_events.alerted_at: pausa abierta > 2 h ya avisada.
--    * work_shifts.long_open_alerted_at: jornada abierta > 12 h ya avisada.
-- ============================================================

alter table public.work_events add column if not exists alerted_at timestamptz;
alter table public.work_shifts add column if not exists long_open_alerted_at timestamptz;

-- Recalcula los datos resumen de una jornada a partir de sus pulsaciones.
create or replace function public.workday_refresh_shift(p_shift uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update public.work_shifts s set
    started_at = coalesce((select min(at) from public.work_events where shift_id = p_shift and kind = 'start'), s.started_at),
    ended_at   = (select max(at) from public.work_events where shift_id = p_shift and kind = 'end'),
    start_km   = coalesce((select km from public.work_events where shift_id = p_shift and kind = 'start' order by at limit 1), s.start_km),
    end_km     = (select km from public.work_events where shift_id = p_shift and kind = 'end' order by at desc limit 1)
  where s.id = p_shift;
$$;
revoke all on function public.workday_refresh_shift(uuid) from public, anon, authenticated;

-- Comprueba que quien llama es el jefe de la empresa de esa jornada.
create or replace function public.workday_owner_check(p_tenant uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_tenant uuid; v_role text;
begin
  if v_uid is null then raise exception 'No autenticado'; end if;
  select tenant_id, role::text into v_tenant, v_role from public.users where id = v_uid;
  if v_tenant is distinct from p_tenant or v_role <> 'owner' then
    raise exception 'Solo el jefe de la empresa puede corregir la jornada';
  end if;
  return v_uid;
end;
$$;
revoke all on function public.workday_owner_check(uuid) from public, anon, authenticated;

create or replace function public.workday_correct(
  p_event uuid, p_at timestamptz, p_km integer default null, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ev public.work_events%rowtype; v_uid uuid; v_prev timestamptz; v_next timestamptz;
begin
  if coalesce(btrim(p_reason), '') = '' then raise exception 'workday_reason_required'; end if;
  select * into v_ev from public.work_events where id = p_event for update;
  if not found then raise exception 'Pulsación no encontrada'; end if;
  v_uid := public.workday_owner_check(v_ev.tenant_id);
  if p_at is null then p_at := v_ev.at; end if;
  if p_at > now() + interval '1 minute' then raise exception 'workday_future'; end if;
  if p_km is not null and p_km < 0 then raise exception 'km no válido'; end if;
  select max(at) into v_prev from public.work_events
   where shift_id = v_ev.shift_id and id <> v_ev.id and (at, created_at) < (v_ev.at, v_ev.created_at);
  select min(at) into v_next from public.work_events
   where shift_id = v_ev.shift_id and id <> v_ev.id and (at, created_at) > (v_ev.at, v_ev.created_at);
  if (v_prev is not null and p_at < v_prev) or (v_next is not null and p_at > v_next) then
    raise exception 'workday_order';
  end if;
  update public.work_events set
    original_at = coalesce(original_at, at),
    original_km = case when original_at is null then km else original_km end,
    at = p_at,
    km = case when kind in ('start', 'end') then coalesce(p_km, km) else km end,
    corrected_by = v_uid, corrected_at = now(), correction_reason = btrim(p_reason)
  where id = v_ev.id;
  perform public.workday_refresh_shift(v_ev.shift_id);
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.workday_correct(uuid, timestamptz, integer, text) from public, anon;
grant execute on function public.workday_correct(uuid, timestamptz, integer, text) to authenticated;

create or replace function public.workday_close(
  p_shift uuid, p_at timestamptz, p_km integer default null, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_sh public.work_shifts%rowtype; v_uid uuid; v_last timestamptz;
begin
  if coalesce(btrim(p_reason), '') = '' then raise exception 'workday_reason_required'; end if;
  select * into v_sh from public.work_shifts where id = p_shift for update;
  if not found or v_sh.status = 'closed' then raise exception 'workday_not_open'; end if;
  v_uid := public.workday_owner_check(v_sh.tenant_id);
  if p_at is null or p_at > now() + interval '1 minute' then raise exception 'workday_future'; end if;
  select max(at) into v_last from public.work_events where shift_id = p_shift;
  if v_last is not null and p_at < v_last then raise exception 'workday_order'; end if;
  insert into public.work_events (shift_id, tenant_id, user_id, kind, at, utc_offset_min, km,
                                  corrected_by, corrected_at, correction_reason)
    values (p_shift, v_sh.tenant_id, v_sh.user_id, 'end', p_at, v_sh.utc_offset_min, p_km,
            v_uid, now(), btrim(p_reason));
  update public.work_shifts set status = 'closed' where id = p_shift;
  perform public.workday_refresh_shift(p_shift);
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.workday_close(uuid, timestamptz, integer, text) from public, anon;
grant execute on function public.workday_close(uuid, timestamptz, integer, text) to authenticated;

notify pgrst, 'reload schema';
