-- ============================================================================
-- 050_loop6_soft_delete_vehicles.sql  (Loop #6 · Iteración 3)
--
-- Baja LÓGICA de vehículos (como ya existe en users.active). El jefe ya no puede
-- borrar físicamente un vehículo: solo darlo de baja (active=false), conservando
-- el historial (carreras, lecturas, etc.). Se retira el privilegio DELETE de
-- `authenticated` sobre vehicles; el admin de plataforma (service_role) conserva
-- el borrado físico para su panel.
--
-- Los conductores ya tienen users.active; su baja lógica se gestiona en el
-- backend (endpoint DELETE /drivers/:id pasa a desactivar).
-- Aditivo e idempotente.
-- ============================================================================
alter table public.vehicles
  add column if not exists active boolean not null default true;

create index if not exists idx_vehicles_active on public.vehicles(tenant_id, active);

-- El jefe NO puede borrar vehículos (solo darlos de baja con update active=false,
-- que la RLS vehicles_owner_write ya permite). service_role mantiene DELETE.
revoke delete on public.vehicles from authenticated;

notify pgrst, 'reload schema';
