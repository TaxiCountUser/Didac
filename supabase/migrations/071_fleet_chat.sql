-- ============================================================
-- TaxiCount - Chat de flota (jefe <-> conductor), un chat por conductor.
--
-- Reemplaza el antiguo canal de "notas/incidencias" (incidents kind='nota'),
-- que era formato tickets. Ahora es un CHAT persistente:
--   - el jefe (owner) ve a todos sus conductores y chatea con cada uno;
--   - el conductor solo chatea con su jefe (su propio hilo);
--   - el ADMIN de plataforma NO tiene acceso a estos mensajes.
--
-- El canal de SOPORTE a la plataforma (incidents kind='app') NO se toca: sigue
-- siendo su propio flujo (TicketsScreen / panel de admin).
--
-- Estos chats NO se autoborran (a diferencia de las notas, que caducaban a los
-- 90 días): no hay limpieza programada sobre esta tabla.
-- ============================================================

create table if not exists public.fleet_messages (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade on update cascade,
  driver_id   uuid not null references public.users(id)   on delete cascade on update cascade,
  sender_id   uuid not null references public.users(id)   on delete cascade on update cascade,
  body        text not null check (length(btrim(body)) > 0),
  created_at  timestamptz not null default now()
);

-- Un chat = (tenant_id, driver_id). Índice para leer el hilo por orden.
create index if not exists idx_fleet_messages_thread
  on public.fleet_messages(tenant_id, driver_id, created_at);

grant select, insert on public.fleet_messages to authenticated, service_role;

alter table public.fleet_messages enable row level security;

-- SELECT: el owner ve los chats de su tenant; el conductor ve SOLO su hilo.
drop policy if exists fleet_messages_select on public.fleet_messages;
create policy fleet_messages_select on public.fleet_messages
  for select to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (public.current_role_name() = 'owner' or driver_id = auth.uid())
  );

-- INSERT: el remitente siempre es uno mismo (sender_id = auth.uid()), en su
-- tenant. El owner puede escribir a cualquier conductor de su tenant; el
-- conductor solo puede escribir en SU propio hilo (driver_id = auth.uid()).
drop policy if exists fleet_messages_insert on public.fleet_messages;
create policy fleet_messages_insert on public.fleet_messages
  for insert to authenticated
  with check (
    tenant_id = public.current_tenant_id()
    and sender_id = auth.uid()
    and (public.current_role_name() = 'owner' or driver_id = auth.uid())
  );

-- Realtime: refrescar el chat en vivo (respeta RLS). Idempotente.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'fleet_messages')
  then
    alter publication supabase_realtime add table public.fleet_messages;
  end if;
end $$;

-- Empezar de cero: borrar las notas de flota antiguas (kind='nota') y sus
-- mensajes. El soporte (kind='app') se conserva.
delete from public.incident_messages im
  using public.incidents i
  where im.incident_id = i.id and i.kind = 'nota';
delete from public.incidents where kind = 'nota';
