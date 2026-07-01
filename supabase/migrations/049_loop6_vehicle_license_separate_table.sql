-- ============================================================================
-- 049_loop6_vehicle_license_separate_table.sql  (Loop #6 · corrige 045)
--
-- PROBLEMA: la 045 ocultó vehicles.license_number con GRANT por columna. Pero
-- PostgREST expande `select=*` (listado) y el RETURNING del insert a TODAS las
-- columnas, así que `authenticated` recibía "permission denied for table
-- vehicles" al crear/listar vehículos.
--
-- SOLUCIÓN robusta: mover license_number a una tabla aparte `vehicle_licenses`
-- con RLS (solo el owner del tenant la ve/gestiona) y restaurar el GRANT normal
-- de `vehicles`. Así `*` vuelve a funcionar, el conductor no ve la licencia
-- (no está en vehicles y la RLS se lo niega) y el owner sí.
--
-- Idempotente. Migra los datos existentes antes de borrar la columna.
-- ============================================================================

-- 1) Tabla separada para el nº de licencia (solo owner).
create table if not exists public.vehicle_licenses (
  vehicle_id     uuid primary key references public.vehicles(id) on delete cascade on update cascade,
  tenant_id      uuid not null references public.tenants(id) on delete cascade on update cascade,
  license_number text,
  updated_at     timestamptz not null default now()
);
create index if not exists idx_vehicle_licenses_tenant on public.vehicle_licenses(tenant_id);

grant select, insert, update, delete on public.vehicle_licenses to authenticated, service_role;
alter table public.vehicle_licenses enable row level security;

drop policy if exists vehicle_licenses_owner on public.vehicle_licenses;
create policy vehicle_licenses_owner on public.vehicle_licenses
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner')
  with check (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner');

-- 2) Migrar los valores existentes (si la columna aún existe en vehicles).
do $$
begin
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'vehicles' and column_name = 'license_number'
  ) then
    insert into public.vehicle_licenses(vehicle_id, tenant_id, license_number)
    select v.id, v.tenant_id, v.license_number
      from public.vehicles v
     where v.license_number is not null
    on conflict (vehicle_id) do nothing;
  end if;
end $$;

-- 3) Restaurar el GRANT normal de vehicles (deshace el bloqueo por columna de 045)
--    y quitar la columna license_number (ya vive en vehicle_licenses).
grant select, insert, update on public.vehicles to authenticated;
alter table public.vehicles drop column if exists license_number;

-- 4) RPCs del owner apuntando a la tabla nueva.
create or replace function public.vehicle_license(p_vehicle uuid)
returns text
language sql stable security definer
set search_path = public
as $$
  select vl.license_number
    from public.vehicle_licenses vl
   where vl.vehicle_id = p_vehicle
     and vl.tenant_id = public.current_tenant_id()
     and public.current_role_name() = 'owner';
$$;
revoke all on function public.vehicle_license(uuid) from public, anon;
grant execute on function public.vehicle_license(uuid) to authenticated, service_role;

create or replace function public.set_vehicle_license(p_vehicle uuid, p_license text)
returns void
language plpgsql security definer
set search_path = public
as $$
declare v_tenant uuid;
begin
  if public.current_role_name() is distinct from 'owner' then
    raise exception 'solo el propietario puede editar el nº de licencia';
  end if;
  select tenant_id into v_tenant from public.vehicles where id = p_vehicle;
  if v_tenant is null or v_tenant is distinct from public.current_tenant_id() then
    raise exception 'vehículo no encontrado en tu empresa';
  end if;
  insert into public.vehicle_licenses(vehicle_id, tenant_id, license_number)
  values (p_vehicle, v_tenant, nullif(btrim(p_license), ''))
  on conflict (vehicle_id) do update
    set license_number = excluded.license_number, updated_at = now();
end;
$$;
revoke all on function public.set_vehicle_license(uuid, text) from public, anon;
grant execute on function public.set_vehicle_license(uuid, text) to authenticated, service_role;

notify pgrst, 'reload schema';
