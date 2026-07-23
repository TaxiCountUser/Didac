-- 077_security_events.sql
-- Registro de eventos de SEGURIDAD (capa B) para la pestaña "Logs" de Auditoría:
-- escalada de privilegios (403 a rutas admin), abuso de API (rate-limit 429), token
-- inválido/manipulado y login por usuario fallido. Distinto del audit trail de
-- negocio (admin_actions_log): aquí van señales de seguridad con metadatos técnicos
-- (method, path, status, trace_id). NUNCA se guarda el cuerpo/headers de la petición
-- (evita almacenar contraseñas/tokens/PII). Solo el backend (service_role) inserta/lee.

create table if not exists public.security_events (
  id          uuid primary key default gen_random_uuid(),
  event_type  text not null,   -- privilege_escalation | rate_limit | invalid_token | login_failed
  actor_id    uuid references public.users(id)   on delete set null,
  tenant_id   uuid references public.tenants(id) on delete set null,
  ip_address  text,
  user_agent  text,
  method      text,
  path        text,
  status_code int,
  trace_id    text,
  details     jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists idx_security_events_created on public.security_events(created_at desc);
create index if not exists idx_security_events_type    on public.security_events(event_type);

grant select, insert on public.security_events to service_role;
alter table public.security_events enable row level security;
-- Sin políticas para authenticated: solo el backend con service_role accede.
