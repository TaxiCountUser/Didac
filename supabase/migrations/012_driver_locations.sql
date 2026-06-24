-- ============================================================
-- TaxiCount - Última ubicación conocida del conductor (localizar vehículo).
--
-- Una fila por conductor (PK = user_id): se sobreescribe (upsert) con su
-- posición más reciente. El jefe la ve en "Localizar vehículo".
-- Privacidad: el conductor comparte su ubicación con permiso del dispositivo;
-- solo la ve el Owner de su propia flota.
-- ============================================================

create table if not exists public.driver_locations (
  user_id    uuid primary key references public.users(id)   on delete cascade on update cascade,
  tenant_id  uuid not null      references public.tenants(id) on delete cascade on update cascade,
  lat        double precision not null,
  lng        double precision not null,
  accuracy   double precision,
  updated_at timestamptz not null default now()
);

create index if not exists idx_driver_locations_tenant on public.driver_locations(tenant_id);

grant select, insert, update, delete on public.driver_locations to authenticated, service_role;
grant select on public.driver_locations to anon;

alter table public.driver_locations enable row level security;

-- SELECT: el owner ve las de su tenant; el conductor, la suya.
drop policy if exists driver_locations_select on public.driver_locations;
create policy driver_locations_select on public.driver_locations
  for select to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (public.current_role_name() = 'owner' or user_id = auth.uid())
  );

-- INSERT/UPDATE: el conductor escribe SOLO la suya (de su tenant).
drop policy if exists driver_locations_insert on public.driver_locations;
create policy driver_locations_insert on public.driver_locations
  for insert to authenticated
  with check (tenant_id = public.current_tenant_id() and user_id = auth.uid());

drop policy if exists driver_locations_update on public.driver_locations;
create policy driver_locations_update on public.driver_locations
  for update to authenticated
  using (tenant_id = public.current_tenant_id() and user_id = auth.uid())
  with check (tenant_id = public.current_tenant_id() and user_id = auth.uid());
