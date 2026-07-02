-- ============================================================================
-- 052_loop6_challenge_config_and_suspicious.sql
--
-- (A) Lleva a system_config los parámetros de retos que estaban fijos en código,
--     para poder editarlos desde el panel de admin sin desplegar:
--       challenge_km_target        (objetivo de km del nivel 1; 100.000)
--       challenge_max_jump         (salto de km sospechoso; 2.000)
--       challenge_max_income       (carrera sospechosa €; 1.500)
--       challenge_seat_credit_cents(crédito por reto completado; 250 = 2,5 €)
--     (challenge_days_required y challenge_100k_euros_enabled ya existen, mig.046)
--
-- (B) challenge_claims.suspicious: el backend marca aquí los logros con señales
--     de posible fraude (salto de km / carrera enorme) para que los revise el
--     ADMIN (ya no se avisa al jefe). El admin decide aceptar o rechazar.
-- ============================================================================
insert into public.system_config(key, value) values
  ('challenge_km_target',         '100000'),
  ('challenge_max_jump',          '2000'),
  ('challenge_max_income',        '1500'),
  ('challenge_seat_credit_cents', '250')
on conflict (key) do nothing;

alter table public.challenge_claims
  add column if not exists suspicious boolean not null default false;

notify pgrst, 'reload schema';
