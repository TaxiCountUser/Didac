-- ============================================================
-- 062 — Bandeja persistente de eventos de Stripe (Mes 2, Strangler-Fig billing)
-- Idempotencia + durabilidad del webhook: cada evento se registra por su
-- event_id ANTES de procesarlo. Un reintento de Stripe con un event_id ya
-- 'processed' se ignora (no duplica cobros); un crash a mitad deja el evento
-- en 'received'/'error' y el reintento lo reprocesa (applyStripeEvent es
-- idempotente). Solo la toca el backend (service_role); RLS sin políticas
-- bloquea a anon/authenticated.
-- ============================================================

create table if not exists public.webhook_events (
  event_id     text primary key,                 -- id del evento de Stripe (evt_...)
  type         text not null,
  status       text not null default 'received',  -- received | processed | error
  tenant_id    uuid,
  attempts     integer not null default 0,
  last_error   text,
  payload      jsonb,                             -- evento completo (por si hay que reprocesar)
  received_at  timestamptz not null default now(),
  processed_at timestamptz
);

create index if not exists idx_webhook_events_status
  on public.webhook_events (status, received_at);

alter table public.webhook_events enable row level security;
-- Sin políticas a propósito: anon/authenticated no acceden; el backend usa
-- service_role, que salta RLS.
grant select, insert, update on public.webhook_events to service_role;
