-- ============================================================================
-- 038_taximeter_itv.sql
-- Punto 6: ITV del TAXÍMETRO (fecha de caducidad), aparte de la ITV general.
-- Aditivo y de bajo riesgo. Idempotente.
-- ============================================================================
alter table public.vehicles
  add column if not exists taximeter_itv_expiry date;

notify pgrst, 'reload schema';
