-- ============================================================
-- TaxiCount - Lecturas de odómetro (km diarios por vehículo).
--
-- Al empezar el día, el conductor apunta los km del coche activo
-- (prerellenados con los últimos conocidos). Sirve para que el
-- propietario sepa los km diarios de cada vehículo. Si el conductor
-- no contesta, se siguen usando los últimos km apuntados.
-- ============================================================

create table if not exists public.odometer_readings (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id)  on delete cascade on update cascade,
  vehicle_id  uuid not null references public.vehicles(id) on delete cascade on update cascade,
  user_id     uuid not null references public.users(id)    on delete cascade on update cascade,
  reading_km  integer not null check (reading_km >= 0),
  taken_at    timestamptz not null default now(),
  created_at  timestamptz not null default now()
);

create index if not exists idx_odometer_tenant         on public.odometer_readings(tenant_id);
create index if not exists idx_odometer_vehicle_taken  on public.odometer_readings(vehicle_id, taken_at desc);

-- Privilegios (tabla nueva: el grant global de 001 no la cubre).
grant select, insert, update, delete on public.odometer_readings to authenticated, service_role;
grant select on public.odometer_readings to anon;

alter table public.odometer_readings enable row level security;

-- SELECT: el owner ve las de su tenant; el driver, las suyas.
drop policy if exists odometer_select on public.odometer_readings;
create policy odometer_select on public.odometer_readings
  for select to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (public.current_role_name() = 'owner' or user_id = auth.uid())
  );

-- INSERT: el conductor apunta las suyas (de su tenant).
drop policy if exists odometer_insert on public.odometer_readings;
create policy odometer_insert on public.odometer_readings
  for insert to authenticated
  with check (
    tenant_id = public.current_tenant_id()
    and user_id = auth.uid()
  );
