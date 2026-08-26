-- ============================================================
-- TaxiCount - Agenda (opción OCULTA y de pago, Fase 1).
--
-- 1) Interruptor POR EMPRESA: tenants.agenda_enabled (por defecto OFF). Solo el
--    admin de plataforma lo activa (vía service_role, desde el panel); el cliente
--    no lo toca y no ve nada mientras esté OFF.
-- 2) Tabla agenda_events: servicios programados, COMPARTIDOS por toda la empresa.
--
-- RLS: los miembros de la empresa ven/gestionan su agenda, y SOLO si su empresa
-- tiene la agenda activada (paywall a nivel de fila). El admin de plataforma NO
-- lee la agenda (dato operativo del cliente, como las transacciones).
-- Google Calendar = Fase 2 (aquí no se toca).
-- ============================================================

-- 1) Interruptor por empresa.
alter table public.tenants
  add column if not exists agenda_enabled boolean not null default false;

-- 2) Servicios de la agenda.
create table if not exists public.agenda_events (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  created_by    uuid references public.users(id) on delete set null,
  scheduled_at  timestamptz not null,            -- día + hora del servicio
  name          text,                            -- cliente o empresa
  pickup        text,                            -- recogida (origen)
  destination   text,                            -- destino
  contact       text,                            -- teléfono o nombre del cliente
  price_approx  numeric(10,2),                   -- precio pactado / aproximado
  note          text,                            -- nota (opcional)
  status        text not null default 'pending', -- pending | done | cancelled
  created_at    timestamptz not null default now()
);
create index if not exists idx_agenda_tenant_time
  on public.agenda_events(tenant_id, scheduled_at);

alter table public.agenda_events enable row level security;

-- Helper: ¿la empresa del que llama tiene la agenda activada? (SECURITY DEFINER
-- para leer tenants sin depender de su propia RLS).
create or replace function public.current_tenant_agenda_enabled()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select agenda_enabled from public.tenants where id = public.current_tenant_id()),
    false)
$$;

-- Ver: cualquier miembro de la empresa, y solo si la agenda está activada.
drop policy if exists agenda_select on public.agenda_events;
create policy agenda_select on public.agenda_events
  for select to authenticated
  using (tenant_id = public.current_tenant_id()
         and public.current_tenant_agenda_enabled());

-- Crear: miembro de la empresa marcándose como autor; solo si activada.
drop policy if exists agenda_insert on public.agenda_events;
create policy agenda_insert on public.agenda_events
  for insert to authenticated
  with check (tenant_id = public.current_tenant_id()
              and created_by = auth.uid()
              and public.current_tenant_agenda_enabled());

-- Editar: cualquier miembro de la empresa (agenda compartida); solo si activada.
drop policy if exists agenda_update on public.agenda_events;
create policy agenda_update on public.agenda_events
  for update to authenticated
  using (tenant_id = public.current_tenant_id() and public.current_tenant_agenda_enabled())
  with check (tenant_id = public.current_tenant_id() and public.current_tenant_agenda_enabled());

-- Borrar: cualquier miembro de la empresa; solo si activada.
drop policy if exists agenda_delete on public.agenda_events;
create policy agenda_delete on public.agenda_events
  for delete to authenticated
  using (tenant_id = public.current_tenant_id() and public.current_tenant_agenda_enabled());

grant select, insert, update, delete on public.agenda_events to authenticated;
