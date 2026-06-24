-- ============================================================
-- TaxiCount - El chofer puede LEER los vehículos que el jefe le ha asignado.
--
-- Problema: 003 dejó vehicles.select SOLO para owners. Por eso, cuando la app
-- del chofer hace el join driver_vehicles -> vehicles (para elegir coche en
-- Ajustes / al empezar el día), RLS bloquea la fila de vehicles y el embed
-- devuelve null => el selector sale vacío aunque el jefe ya haya asignado coche.
--
-- Solución: el owner sigue viendo todos los vehículos de su tenant; el chofer
-- puede leer únicamente los vehículos vinculados a él en driver_vehicles.
-- No le damos write: la asignación la sigue gestionando solo el owner.
-- ============================================================

drop policy if exists vehicles_select on public.vehicles;
create policy vehicles_select on public.vehicles
  for select to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (
      public.current_role_name() = 'owner'
      or exists (
        select 1
        from public.driver_vehicles dv
        where dv.vehicle_id = public.vehicles.id
          and dv.user_id = auth.uid()
      )
    )
  );
