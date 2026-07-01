-- ============================================================================
-- 046_loop6_challenge_config.sql  (Loop #6 · Iteración 1)
--
-- Claves de configuración de los retos en system_config (lectura pública; las
-- lee el backend en la Iteración 2):
--   - challenge_100k_euros_enabled = false  -> se retira el reto de 100.000 €.
--   - challenge_days_required       = 365   -> el reto de días pasa de 300 a 365
--                                              y deja de exigir un mínimo aparte.
--
-- Idempotente. No pisa un valor ya presente (convención del repo).
-- ============================================================================
insert into public.system_config(key, value) values
  ('challenge_100k_euros_enabled', 'false'),
  ('challenge_days_required',      '365')
on conflict (key) do nothing;

notify pgrst, 'reload schema';
