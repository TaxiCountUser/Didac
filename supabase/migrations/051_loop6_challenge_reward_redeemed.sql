-- ============================================================================
-- 051_loop6_challenge_reward_redeemed.sql  (Loop #6 · Iteración 7)
--
-- Marca de canje del premio del reto: "1 mes-asiento gratis" al jefe por cada
-- reto completado. Cuando el backend abona el crédito en Stripe, fija
-- reward_redeemed_at para no volver a abonarlo (idempotencia). NULL = pendiente.
-- Aditivo e idempotente.
-- ============================================================================
alter table public.challenge_claims
  add column if not exists reward_redeemed_at timestamptz;

create index if not exists idx_challenge_claims_pending_reward
  on public.challenge_claims (status)
  where reward_redeemed_at is null;

notify pgrst, 'reload schema';
