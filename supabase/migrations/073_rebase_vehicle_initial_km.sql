-- ============================================================================
-- 073_rebase_vehicle_initial_km.sql
--
-- Corregir el km inicial de un vehículo CONSERVANDO la distancia ya recorrida.
--
-- El progreso del reto de km se calcula EN VIVO como (lectura - km inicial). Si
-- el jefe se equivocó al dar de alta el vehículo y corrige el km inicial, NO
-- queremos que los km ya recorridos cambien: son un hecho real. Por eso, en vez
-- de tocar solo initial_odometer (que dispararía o borraría el recorrido), se
-- REESCALA toda la escala del odómetro de ESE vehículo por el mismo delta
-- (delta = nuevo_inicial - inicial_actual):
--   - odometer_readings.reading_km += delta
--   - transactions.odometer_km      += delta  (solo las de ese vehículo)
--   - vehicles.initial_odometer / registered_km = nuevo_inicial
--   - vehicles.last_revision_km    += delta    (km de la última revisión, misma escala)
--
-- Así (lectura - inicial) queda EXACTAMENTE igual (los km recorridos se
-- conservan) y el odómetro actual pasa a reflejar la escala corregida (p. ej.
-- 1000 km + 30 recorridos -> corregir inicial a 2000 deja el odómetro en 2030 y
-- el reto sigue marcando 30). Atómico (una sola función) y solo para el OWNER
-- de la empresa dueña del vehículo.
-- ============================================================================

create or replace function public.rebase_vehicle_initial_km(p_vehicle uuid, p_new_initial integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant uuid;
  v_old    integer;
  v_delta  integer;
begin
  if public.current_role_name() is distinct from 'owner' then
    raise exception 'solo el propietario puede corregir el km inicial';
  end if;
  if p_new_initial is null or p_new_initial < 0 then
    raise exception 'km inicial invalido';
  end if;

  select tenant_id, coalesce(nullif(initial_odometer, 0), registered_km, 0)
    into v_tenant, v_old
    from public.vehicles
   where id = p_vehicle;
  if v_tenant is null or v_tenant is distinct from public.current_tenant_id() then
    raise exception 'vehiculo no encontrado en tu empresa';
  end if;

  v_delta := p_new_initial - v_old;

  if v_delta <> 0 then
    -- Reescala todas las lecturas del vehículo por el mismo delta: la distancia
    -- recorrida (lectura - inicial) se conserva exactamente.
    update public.odometer_readings
       set reading_km = reading_km + v_delta
     where vehicle_id = p_vehicle;
    update public.transactions
       set odometer_km = odometer_km + v_delta
     where vehicle_id = p_vehicle and odometer_km is not null;
  end if;

  update public.vehicles
     set initial_odometer = p_new_initial,
         registered_km    = p_new_initial,
         last_revision_km = case when last_revision_km is not null
                                 then last_revision_km + v_delta else null end
   where id = p_vehicle;
end;
$$;

revoke all on function public.rebase_vehicle_initial_km(uuid, integer) from public, anon;
grant execute on function public.rebase_vehicle_initial_km(uuid, integer) to authenticated, service_role;

notify pgrst, 'reload schema';
