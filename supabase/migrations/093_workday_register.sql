-- ============================================================
-- TaxiCount - 093: REGISTRO DE JORNADA (legal), fase 1.
--
-- En España las empresas deben registrar la jornada diaria de sus asalariados
-- (inicio y fin, art. 34.9 ET) y conservarla 4 años; TaxiCount lo guarda como el
-- resto de datos (empresa activa: siempre; empresa cerrada: 5 años, mig. 044).
--
-- * tenants.workday_required: interruptor de la empresa (por defecto APAGADO).
--   Lo cambia SOLO el jefe/autónomo (RPC set_workday_required). Apagado = todo
--   como antes. Encendido = el conductor marca Iniciar / Pausa / Reanudar /
--   Finalizar y no puede apuntar carreras sin jornada iniciada (lo exige la app).
-- * work_shifts: una fila por jornada (estado open / paused / closed).
-- * work_events: cada pulsación (start / pause / resume / end), INMUTABLE para el
--   conductor. La hora es la del SERVIDOR (now(): nadie puede adelantar o atrasar
--   el reloj del móvil para hacer trampa) y se guarda la diferencia horaria del
--   móvil (utc_offset_min) para mostrarla a su hora local, como las carreras.
-- * Solo el jefe corrige (fase 2, RPC aparte) dejando el valor original, quién,
--   cuándo y el motivo (original_at / corrected_by / correction_reason).
-- * El cliente NO puede insertar/editar/borrar directamente: solo con las RPC.
-- ============================================================

alter table public.tenants
  add column if not exists workday_required boolean not null default false;

create table if not exists public.work_shifts (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade on update cascade,
  user_id         uuid not null references public.users(id)   on delete cascade on update cascade,
  vehicle_id      uuid references public.vehicles(id) on delete set null,
  status          text not null default 'open' check (status in ('open', 'paused', 'closed')),
  started_at      timestamptz not null default now(),
  ended_at        timestamptz,
  start_km        integer check (start_km is null or start_km >= 0),
  end_km          integer check (end_km is null or end_km >= 0),
  utc_offset_min  smallint check (utc_offset_min is null or utc_offset_min between -840 and 840),
  created_at      timestamptz not null default now()
);
-- Como mucho UNA jornada abierta (o en pausa) por persona.
create unique index if not exists work_shifts_one_open
  on public.work_shifts (user_id) where status <> 'closed';
create index if not exists work_shifts_tenant_started on public.work_shifts (tenant_id, started_at desc);
create index if not exists work_shifts_user_started   on public.work_shifts (user_id, started_at desc);

create table if not exists public.work_events (
  id                 uuid primary key default gen_random_uuid(),
  shift_id           uuid not null references public.work_shifts(id) on delete cascade,
  tenant_id          uuid not null references public.tenants(id)    on delete cascade on update cascade,
  user_id            uuid not null references public.users(id)      on delete cascade on update cascade,
  kind               text not null check (kind in ('start', 'pause', 'resume', 'end')),
  at                 timestamptz not null default now(),
  utc_offset_min     smallint check (utc_offset_min is null or utc_offset_min between -840 and 840),
  km                 integer check (km is null or km >= 0),
  -- Corrección del jefe (fase 2): se conserva el valor original.
  original_at        timestamptz,
  original_km        integer,
  corrected_by       uuid references public.users(id) on delete set null,
  corrected_at       timestamptz,
  correction_reason  text,
  created_at         timestamptz not null default now()
);
create index if not exists work_events_shift on public.work_events (shift_id, at);
create index if not exists work_events_tenant_at on public.work_events (tenant_id, at desc);

-- Lectura: el jefe ve las de su empresa; el conductor, las suyas. Escritura: nadie
-- directamente (sin políticas de insert/update/delete + revoke): solo las RPC.
alter table public.work_shifts enable row level security;
alter table public.work_events enable row level security;
revoke all on public.work_shifts, public.work_events from anon, authenticated;
grant select on public.work_shifts, public.work_events to authenticated;
grant all on public.work_shifts, public.work_events to service_role;

drop policy if exists work_shifts_select on public.work_shifts;
create policy work_shifts_select on public.work_shifts for select to authenticated
  using (tenant_id = public.current_tenant_id()
         and (public.current_role_name() = 'owner' or user_id = auth.uid()));
drop policy if exists work_events_select on public.work_events;
create policy work_events_select on public.work_events for select to authenticated
  using (tenant_id = public.current_tenant_id()
         and (public.current_role_name() = 'owner' or user_id = auth.uid()));

-- ------------------------------------------------------------
-- Interruptor de la empresa (solo el jefe / autónomo).
-- ------------------------------------------------------------
create or replace function public.set_workday_required(p_on boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid(); v_tenant uuid; v_role text;
begin
  if v_uid is null then raise exception 'No autenticado'; end if;
  select tenant_id, role::text into v_tenant, v_role from public.users where id = v_uid;
  if v_tenant is null then raise exception 'No perteneces a ninguna empresa'; end if;
  if v_role <> 'owner' then raise exception 'Solo el propietario puede cambiar esto'; end if;
  update public.tenants set workday_required = coalesce(p_on, false) where id = v_tenant;
  return coalesce(p_on, false);
end;
$$;
revoke all on function public.set_workday_required(boolean) from public, anon;
grant execute on function public.set_workday_required(boolean) to authenticated;

-- ------------------------------------------------------------
-- Una pulsación del conductor: start / pause / resume / end.
-- Comprueba el orden (no se puede pausar sin haber iniciado, etc.) y devuelve el
-- estado actual de la jornada. Hora = la del servidor.
-- ------------------------------------------------------------
create or replace function public.workday_action(
  p_kind text, p_offset smallint default null, p_km integer default null, p_vehicle uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid(); v_tenant uuid; v_active boolean; v_deleted timestamptz;
  v_shift public.work_shifts%rowtype; v_now timestamptz := now();
begin
  if v_uid is null then raise exception 'No autenticado'; end if;
  select tenant_id, active, deleted_at into v_tenant, v_active, v_deleted
    from public.users where id = v_uid;
  if v_tenant is null or v_active is false or v_deleted is not null then
    raise exception 'Cuenta no válida';
  end if;
  if p_km is not null and p_km < 0 then raise exception 'km no válido'; end if;
  if p_vehicle is not null and not exists (
       select 1 from public.vehicles where id = p_vehicle and tenant_id = v_tenant) then
    p_vehicle := null;
  end if;

  select * into v_shift from public.work_shifts
   where user_id = v_uid and status <> 'closed' for update;

  if p_kind = 'start' then
    if found then raise exception 'workday_already_open'; end if;
    insert into public.work_shifts (tenant_id, user_id, vehicle_id, status, started_at, start_km, utc_offset_min)
      values (v_tenant, v_uid, p_vehicle, 'open', v_now, p_km, p_offset)
      returning * into v_shift;
  elsif p_kind = 'pause' then
    if not found or v_shift.status <> 'open' then raise exception 'workday_not_running'; end if;
    update public.work_shifts set status = 'paused' where id = v_shift.id returning * into v_shift;
  elsif p_kind = 'resume' then
    if not found or v_shift.status <> 'paused' then raise exception 'workday_not_paused'; end if;
    update public.work_shifts set status = 'open' where id = v_shift.id returning * into v_shift;
  elsif p_kind = 'end' then
    if not found then raise exception 'workday_not_open'; end if;
    -- Finalizar en pausa: la pausa termina con la jornada (no hace falta Reanudar).
    update public.work_shifts set status = 'closed', ended_at = v_now, end_km = p_km
     where id = v_shift.id returning * into v_shift;
  else
    raise exception 'Acción no válida';
  end if;

  insert into public.work_events (shift_id, tenant_id, user_id, kind, at, utc_offset_min, km)
    values (v_shift.id, v_tenant, v_uid, p_kind, v_now, p_offset,
            case when p_kind in ('start', 'end') then p_km end);

  return jsonb_build_object('shift_id', v_shift.id, 'status', v_shift.status,
                            'started_at', v_shift.started_at, 'at', v_now);
end;
$$;
revoke all on function public.workday_action(text, smallint, integer, uuid) from public, anon;
grant execute on function public.workday_action(text, smallint, integer, uuid) to authenticated;

notify pgrst, 'reload schema';
