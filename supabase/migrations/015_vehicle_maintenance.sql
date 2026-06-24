-- ============================================================
-- TaxiCount - Ficha de mantenimiento por vehículo (solo panel del jefe).
--
-- El jefe quiere controlar, por coche, el estado de:
--   - ITV         : próxima fecha de inspección.
--   - Seguro      : próxima fecha de renovación.
--   - Tarjeta de transporte: fecha del último visado/renovación + periodo
--                   (en España el visado periódico se suprimió en 2019; se deja
--                   el periodo configurable, por defecto 4 años, por si el
--                   operador quiere seguir avisándose).
--   - Revisiones  : intervalo en km + km del coche en la última revisión
--                   (para calcular cuántos km quedan hasta la siguiente).
--
-- Los km "actuales" del coche NO se guardan aquí: se derivan de odometer_readings
-- / transactions (lastOdometer). Aquí solo guardamos la configuración/fechas.
-- Solo el owner gestiona estos campos (RLS de vehicles ya lo cubre: write owner).
-- ============================================================

alter table public.vehicles
  add column if not exists itv_expiry              date,
  add column if not exists insurance_expiry        date,
  add column if not exists transport_card_date     date,
  add column if not exists transport_card_years    int  not null default 4,
  add column if not exists revision_interval_km    int  not null default 15000,
  add column if not exists last_revision_km        int,
  add column if not exists maintenance_notes        text;

-- Recarga el esquema en PostgREST tras aplicar.
