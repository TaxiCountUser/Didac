-- ============================================================================
-- 047_loop6_error_reports.sql  (Loop #6 · Iteración 1)
--
-- Informes de error enviados desde la app por el conductor. Van al ADMIN de la
-- plataforma (panel completo, vía backend/service_role) y el JEFE de la flota
-- SOLO PUEDE VERLOS (sin modificar, borrar ni responder). Es una tabla aparte
-- de incidents/incident_messages, así que NO aparece en "Mensajes al jefe".
--
-- El backend (Iteración 3) creará el endpoint de alta + notificaciones push a
-- admin y jefe, y el cambio de estado (solo admin).
-- ============================================================================
create table if not exists public.error_reports (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid references public.tenants(id) on delete set null on update cascade,
  user_id        uuid references public.users(id)   on delete set null on update cascade,
  description    text not null,
  screenshot_url text,
  device_info    text,
  status         text not null default 'new'
                 check (status in ('new', 'viewed', 'in_progress', 'resolved')),
  created_at     timestamptz not null default now(),
  reviewed_at    timestamptz
);

create index if not exists idx_error_reports_tenant  on public.error_reports(tenant_id);
create index if not exists idx_error_reports_status  on public.error_reports(status);
create index if not exists idx_error_reports_created on public.error_reports(created_at desc);

-- Privilegios (tabla nueva; el grant global de 001 no la cubre). El authenticated
-- solo puede leer (RLS) e insertar; NO update/delete (el jefe no puede tocar los
-- informes). El admin los gestiona con service_role desde el backend.
grant select, insert on public.error_reports to authenticated;
grant select, insert, update, delete on public.error_reports to service_role;

alter table public.error_reports enable row level security;

-- SELECT: el autor ve el suyo; el owner ve (solo lectura) los de su empresa.
drop policy if exists error_reports_select on public.error_reports;
create policy error_reports_select on public.error_reports
  for select to authenticated
  using (
    user_id = auth.uid()
    or (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner')
  );

-- INSERT: cualquier usuario reporta desde su propia cuenta.
drop policy if exists error_reports_insert on public.error_reports;
create policy error_reports_insert on public.error_reports
  for insert to authenticated
  with check (user_id = auth.uid());

notify pgrst, 'reload schema';
