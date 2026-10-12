-- ============================================================
-- TaxiCount - Agenda: ASIGNAR un servicio a un conductor concreto.
--
-- Modelo:
--   * agenda_events.assigned_to = NULL  -> servicio de TODA la flota (lo ve
--     cualquier miembro de la empresa). Es el estado por defecto: cuando un
--     chófer crea un servicio, lo ven todos.
--   * assigned_to = <conductor>         -> solo lo ven ESE conductor y el JEFE.
--
-- Quién asigna: SOLO el titular (owner). La RLS es la frontera real, así que un
-- trigger impide que un conductor ponga/cambie assigned_to (la UI ya lo oculta,
-- pero aquí lo blindamos).
-- ============================================================

-- 1) Columna de asignación (NULL = toda la flota).
alter table public.agenda_events
  add column if not exists assigned_to uuid references public.users(id) on delete set null;

create index if not exists idx_agenda_assigned
  on public.agenda_events(assigned_to);

-- 2) Visibilidad por fila: miembro de la empresa + agenda activada + el servicio
--    es de toda la flota, o está asignado a mí, o soy el titular.
drop policy if exists agenda_select on public.agenda_events;
create policy agenda_select on public.agenda_events
  for select to authenticated
  using (tenant_id = public.current_tenant_id()
         and public.current_tenant_agenda_enabled()
         and (assigned_to is null
              or assigned_to = auth.uid()
              or public.current_role_name() = 'owner'));

-- 3) Editar/borrar: misma visibilidad (un conductor no toca servicios de otro).
drop policy if exists agenda_update on public.agenda_events;
create policy agenda_update on public.agenda_events
  for update to authenticated
  using (tenant_id = public.current_tenant_id()
         and public.current_tenant_agenda_enabled()
         and (assigned_to is null
              or assigned_to = auth.uid()
              or public.current_role_name() = 'owner'))
  with check (tenant_id = public.current_tenant_id()
              and public.current_tenant_agenda_enabled());

drop policy if exists agenda_delete on public.agenda_events;
create policy agenda_delete on public.agenda_events
  for delete to authenticated
  using (tenant_id = public.current_tenant_id()
         and public.current_tenant_agenda_enabled()
         and (assigned_to is null
              or assigned_to = auth.uid()
              or public.current_role_name() = 'owner'));

-- (agenda_insert se mantiene de 084: created_by = auth.uid(), tenant + activada.)

-- 4) Blindaje: solo el titular puede poner o cambiar la asignación, y el
--    conductor asignado debe pertenecer a la empresa.
create or replace function public.agenda_guard_assign()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.assigned_to is not null and public.current_role_name() <> 'owner' then
      raise exception 'Solo el titular puede asignar un servicio a un conductor';
    end if;
  elsif tg_op = 'UPDATE' then
    if new.assigned_to is distinct from old.assigned_to
       and public.current_role_name() <> 'owner' then
      raise exception 'Solo el titular puede asignar o reasignar un servicio';
    end if;
  end if;

  if new.assigned_to is not null
     and not exists (select 1 from public.users u
                     where u.id = new.assigned_to and u.tenant_id = new.tenant_id) then
    raise exception 'El conductor asignado no pertenece a la empresa';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_agenda_guard_assign on public.agenda_events;
create trigger trg_agenda_guard_assign
  before insert or update on public.agenda_events
  for each row execute function public.agenda_guard_assign();
