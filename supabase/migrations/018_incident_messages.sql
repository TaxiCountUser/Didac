-- ============================================================
-- TaxiCount - Chat por incidencia (jefe <-> conductor).
-- Ambas partes pueden escribir MIENTRAS la incidencia no esté 'resuelta'.
-- Al marcarla resuelta, deja de poder escribirse (RLS de insert lo impide).
-- ============================================================

create table if not exists public.incident_messages (
  id          uuid primary key default gen_random_uuid(),
  incident_id uuid not null references public.incidents(id) on delete cascade,
  tenant_id   uuid not null references public.tenants(id)   on delete cascade,
  user_id     uuid not null references public.users(id)     on delete cascade,
  body        text not null,
  created_at  timestamptz not null default now()
);
create index if not exists idx_incident_messages_incident
  on public.incident_messages(incident_id, created_at);

grant select, insert, delete on public.incident_messages to authenticated, service_role;

alter table public.incident_messages enable row level security;

-- SELECT: el owner del tenant, o el autor de la incidencia.
drop policy if exists incident_messages_select on public.incident_messages;
create policy incident_messages_select on public.incident_messages
  for select to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (
      public.current_role_name() = 'owner'
      or exists (select 1 from public.incidents i
                 where i.id = incident_id and i.user_id = auth.uid())
    )
  );

-- INSERT: owner o autor, solo si la incidencia NO está resuelta.
drop policy if exists incident_messages_insert on public.incident_messages;
create policy incident_messages_insert on public.incident_messages
  for insert to authenticated
  with check (
    tenant_id = public.current_tenant_id()
    and user_id = auth.uid()
    and exists (
      select 1 from public.incidents i
      where i.id = incident_id
        and i.status <> 'resuelta'
        and (public.current_role_name() = 'owner' or i.user_id = auth.uid())
    )
  );

-- DELETE: solo el owner del tenant (limpieza).
drop policy if exists incident_messages_owner_delete on public.incident_messages;
create policy incident_messages_owner_delete on public.incident_messages
  for delete to authenticated
  using (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner');
