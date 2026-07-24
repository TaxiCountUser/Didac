-- 079_service_status_log.sql
-- Histórico de estado de los SERVICIOS (push, webhooks, groq, BD, API…) para calcular
-- UPTIME % y tendencias en Monitorización. Hasta ahora markService() solo guardaba la
-- ÚLTIMA foto en system_config (svc_<name>), sin histórico. Ahora, además, se añade una
-- fila aquí en cada check. Solo el backend (service_role) escribe/lee.

create table if not exists public.service_status_log (
  id         bigint generated always as identity primary key,
  service    text        not null,
  ok         boolean     not null,
  checked_at timestamptz not null default now()
);
create index if not exists idx_service_status_log_svc_at
  on public.service_status_log(service, checked_at desc);

grant select, insert, delete on public.service_status_log to service_role;
alter table public.service_status_log enable row level security;
-- Sin políticas para authenticated: solo el backend con service_role accede.
