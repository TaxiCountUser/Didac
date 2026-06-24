-- ============================================================
-- TaxiCount - Asignación conductor <-> vehículo (M:N).
--
-- El Owner decide a qué vehículos puede acceder cada conductor:
--   - desde un coche, asignarle uno o varios choferes;
--   - desde un chofer, asignarle uno o varios coches.
-- Si un conductor tiene 1 vehículo, la app lo usa automáticamente; si
-- tiene varios, elige cuál al registrar (o al empezar el día).
-- Esto permite imputar gastos/carreras y km a cada coche con exactitud.
-- ============================================================

create table if not exists public.driver_vehicles (
  tenant_id  uuid not null references public.tenants(id)  on delete cascade on update cascade,
  user_id    uuid not null references public.users(id)    on delete cascade on update cascade,
  vehicle_id uuid not null references public.vehicles(id) on delete cascade on update cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, vehicle_id)
);

create index if not exists idx_driver_vehicles_tenant  on public.driver_vehicles(tenant_id);
create index if not exists idx_driver_vehicles_user    on public.driver_vehicles(user_id);
create index if not exists idx_driver_vehicles_vehicle on public.driver_vehicles(vehicle_id);

-- Privilegios (tabla nueva: el grant global de 001 no la cubre).
grant select, insert, update, delete on public.driver_vehicles to authenticated, service_role;
grant select on public.driver_vehicles to anon;

alter table public.driver_vehicles enable row level security;

-- SELECT: el owner ve todas las de su tenant; el driver, solo las suyas.
drop policy if exists driver_vehicles_select on public.driver_vehicles;
create policy driver_vehicles_select on public.driver_vehicles
  for select to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (public.current_role_name() = 'owner' or user_id = auth.uid())
  );

-- WRITE (insert/update/delete): solo el owner, dentro de su tenant.
drop policy if exists driver_vehicles_owner_write on public.driver_vehicles;
create policy driver_vehicles_owner_write on public.driver_vehicles
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner')
  with check (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner');
