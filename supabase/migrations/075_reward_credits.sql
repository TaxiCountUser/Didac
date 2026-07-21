-- 075_reward_credits.sql
-- Recompensas (retos y referidos) pasan de "días gratis que extienden trial_ends_at"
-- (cosmético para un cliente de pago: Stripe factura igual) a CRÉDITO REAL en Stripe
-- aplicado a la próxima factura (customer balance). Guardamos, por recompensa:
--   credit_cents  = € (céntimos) acreditados en Stripe en el momento de concederla.
--   stripe_txn_id = id de la balance transaction, para poder revertirla en un clawback.
-- Valor: reto = 1 asiento·mes; referido = N días de flota; ambos a la tarifa EFECTIVA
-- (neta de cupón) del último pago del cliente. Aditiva y no destructiva.

alter table public.subscription_extensions
  add column if not exists credit_cents  int  not null default 0,
  add column if not exists stripe_txn_id text;

alter table public.referral_milestone_rewards
  add column if not exists credit_cents  int  not null default 0,
  add column if not exists stripe_txn_id text;
