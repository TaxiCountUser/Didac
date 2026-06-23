-- ============================================================
-- TaxiCount - Incidencias / notas al jefe.
--
-- Dos usos en una sola tabla (campo kind):
--   'nota' -> mensaje del conductor al jefe (p. ej. "ruido en la rueda
--             derecha"). El Owner las ve en su panel de Incidencias.
--   'app'  -> reporte de un fallo de la app (ticket).
-- El Owner puede marcarlas como resueltas.
-- ============================================================

create table if not exists public.incidents (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade on update cascade,
  user_id     uuid not null references public.users(id)   on delete cascade on update cascade,
  kind        text not null default 'nota' check (kind in ('nota', 'app')),
  body        text not null check (length(btrim(body)) > 0),
  status      text not null default 'abierta' check (status in ('abierta', 'resuelta')),
  created_at  timestamptz not null default now()
);

create index if not exists idx_incidents_tenant on public.incidents(tenant_id, created_at desc);
create index if not exists idx_incidents_user   on public.incidents(user_id);

grant select, insert, update, delete on public.incidents to authenticated, service_role;
grant select on public.incidents to anon;

alter table public.incidents enable row level security;

-- SELECT: el owner ve las de su tenant; el autor (conductor) ve las suyas.
drop policy if exists incidents_select on public.incidents;
create policy incidents_select on public.incidents
  for select to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (public.current_role_name() = 'owner' or user_id = auth.uid())
  );

-- INSERT: cualquier autenticado crea las suyas (de su tenant).
drop policy if exists incidents_insert on public.incidents;
create policy incidents_insert on public.incidents
  for insert to authenticated
  with check (
    tenant_id = public.current_tenant_id()
    and user_id = auth.uid()
  );

-- UPDATE: el owner gestiona el estado (resuelta) dentro de su tenant.
drop policy if exists incidents_owner_update on public.incidents;
create policy incidents_owner_update on public.incidents
  for update to authenticated
  using (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner')
  with check (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner');
