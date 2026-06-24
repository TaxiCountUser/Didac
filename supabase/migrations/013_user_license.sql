-- ============================================================
-- TaxiCount - Número de licencia del conductor.
-- Lo edita el propio conductor en su app (RLS users_update_self).
-- ============================================================

alter table public.users
  add column if not exists license_number text;
