-- ============================================================================
-- 083_vehicle_maintenance_periods.sql
-- Periodo de renovación (en meses) para ITV, ITV del taxímetro y seguro. Deja
-- que el propietario diga "cada 6 meses / 1 año" y la app calcule la próxima
-- fecha de caducidad; el aviso push a 15 días (cron maintenance-reminders) ya
-- funciona sobre esas fechas. Aditivo y de bajo riesgo. Idempotente.
--
-- No hace falta grant/RLS extra: los vehículos se actualizan por la política de
-- fila del propietario (igual que itv_expiry / taximeter_itv_expiry, mig. 038).
-- ============================================================================
alter table public.vehicles
  add column if not exists itv_period_months            integer,
  add column if not exists taximeter_itv_period_months  integer,
  add column if not exists insurance_period_months       integer;

notify pgrst, 'reload schema';
