-- ============================================================================
-- 045_loop6_vehicle_km_and_license.sql  (Loop #6 · Iteración 1)
--
-- (A) vehicles.initial_odometer: km del vehículo en el momento del alta. Será
--     OBLIGATORIO en la app (validación en frontend/API, Iteración 5). El reto de
--     100.000 km pasa a medirse POR VEHÍCULO desde este valor (Iteración 2).
--
-- (B) license_number (nº de licencia): la columna YA EXISTE (mig. 013). Aquí
--     restringimos su visibilidad a SOLO el owner. Como owner y driver comparten
--     el rol de BD `authenticated` y Flutter lee `vehicles` directo de PostgREST,
--     ni RLS por fila ni GRANT por columna pueden distinguir owner/driver. La
--     solución robusta: retirar license_number del GRANT de columnas de
--     `authenticated` (nadie la lee/escribe por PostgREST) y que el owner la
--     consulte/edite con RPCs SECURITY DEFINER que comprueban su rol y tenant.
--
-- Aditivo e idempotente. service_role conserva acceso completo (grant global).
-- ============================================================================

-- (A) -----------------------------------------------------------------------
alter table public.vehicles
  add column if not exists initial_odometer int not null default 0;

-- license_number: se creó en la mig. 013, pero no en todos los entornos. La
-- garantizamos aquí para que esta migración sea autosuficiente (idempotente).
alter table public.vehicles
  add column if not exists license_number text;

-- Backfill de coches existentes: km más reciente conocido del vehículo (última
-- lectura de odómetro). Para flotas ya en uso empezamos a contar "desde ahora".
update public.vehicles v
   set initial_odometer = sub.km
  from (
    select vehicle_id, max(reading_km) as km
      from public.odometer_readings
     group by vehicle_id
  ) sub
 where sub.vehicle_id = v.id
   and v.initial_odometer = 0;

-- Sin lecturas pero con registered_km fijado al alta -> úsalo como base.
update public.vehicles
   set initial_odometer = registered_km
 where initial_odometer = 0
   and registered_km is not null
   and registered_km > 0;

-- (B) -----------------------------------------------------------------------
-- Se pasa de GRANT a nivel de tabla (global de 001) a GRANT por columnas para
-- `authenticated`, excluyendo license_number. DELETE se deja intacto (RLS por
-- fila ya lo limita al owner; la baja lógica llega en la Iteración 3).
revoke select, insert, update on public.vehicles from authenticated;

grant select (
  id, tenant_id, license_plate, model, created_at,
  itv_expiry, insurance_expiry, transport_card_date, transport_card_years,
  revision_interval_km, last_revision_km, maintenance_notes,
  taximeter_itv_expiry, registered_km, initial_odometer
) on public.vehicles to authenticated;

grant insert (
  tenant_id, license_plate, model,
  itv_expiry, insurance_expiry, transport_card_date, transport_card_years,
  revision_interval_km, last_revision_km, maintenance_notes,
  taximeter_itv_expiry, registered_km, initial_odometer
) on public.vehicles to authenticated;

grant update (
  license_plate, model,
  itv_expiry, insurance_expiry, transport_card_date, transport_card_years,
  revision_interval_km, last_revision_km, maintenance_notes,
  taximeter_itv_expiry, registered_km, initial_odometer
) on public.vehicles to authenticated;

-- Owner: leer el nº de licencia de un vehículo de su empresa.
create or replace function public.vehicle_license(p_vehicle uuid)
returns text
language sql stable security definer
set search_path = public
as $$
  select v.license_number
    from public.vehicles v
   where v.id = p_vehicle
     and v.tenant_id = public.current_tenant_id()
     and public.current_role_name() = 'owner';
$$;
revoke all on function public.vehicle_license(uuid) from public, anon;
grant execute on function public.vehicle_license(uuid) to authenticated, service_role;

-- Owner: fijar/actualizar el nº de licencia (solo su empresa).
create or replace function public.set_vehicle_license(p_vehicle uuid, p_license text)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if public.current_role_name() is distinct from 'owner' then
    raise exception 'solo el propietario puede editar el nº de licencia';
  end if;
  update public.vehicles
     set license_number = nullif(btrim(p_license), '')
   where id = p_vehicle
     and tenant_id = public.current_tenant_id();
  if not found then
    raise exception 'vehículo no encontrado en tu empresa';
  end if;
end;
$$;
revoke all on function public.set_vehicle_license(uuid, text) from public, anon;
grant execute on function public.set_vehicle_license(uuid, text) to authenticated, service_role;

notify pgrst, 'reload schema';
