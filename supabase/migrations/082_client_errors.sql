-- 082_client_errors.sql
-- Telemetría de errores del CLIENTE (excepciones de la app), para verlos AGREGADOS
-- en Auditoría y detectar problemas recurrentes. Solo METADATOS técnicos: mensaje
-- (truncado), pantalla, versión, plataforma; NUNCA datos de negocio ni PII. Distinto
-- de error_reports (informes que envía el usuario a mano) y de security_events. Solo
-- el backend (service_role) inserta/lee.

create table if not exists public.client_errors (
  id          bigint generated always as identity primary key,
  message     text not null,
  screen      text,
  platform    text,
  app_version text,
  user_id     uuid references public.users(id)   on delete set null,
  tenant_id   uuid references public.tenants(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists idx_client_errors_created on public.client_errors(created_at desc);
create index if not exists idx_client_errors_message on public.client_errors(message);

grant select, insert, delete on public.client_errors to service_role;
alter table public.client_errors enable row level security;
-- Sin políticas para authenticated: solo el backend con service_role accede.
