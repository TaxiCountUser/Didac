-- ============================================================================
-- 036_admin_actions_log.sql
-- Loop #5 — Dashboard de Super Admin (Referidos + Super Retos).
--
-- Registro de auditoría de acciones administrativas sensibles: edición de la
-- configuración de hitos, bloqueo/desbloqueo de referidos, ajustes manuales de
-- recompensas, resolución de alertas, etc. (qué admin, cuándo, sobre qué).
--
-- Solo crea estructura nueva. Aditivo y de bajo riesgo. Idempotente.
-- ============================================================================
create table if not exists public.admin_actions_log (
  id           uuid primary key default gen_random_uuid(),
  admin_id     uuid references public.users(id) on delete set null,
  action_type  text not null,             -- p.ej. 'referral_block', 'referral_config_update'
  target_type  text,                       -- 'referral' | 'challenge' | 'config' | ...
  target_id    text,                       -- id del objeto afectado (uuid o clave)
  details      jsonb,                      -- contexto libre (cambios, motivo, etc.)
  ip_address   text,
  created_at   timestamptz not null default now()
);
create index if not exists idx_admin_actions_created on public.admin_actions_log(created_at desc);
create index if not exists idx_admin_actions_admin   on public.admin_actions_log(admin_id, created_at desc);
create index if not exists idx_admin_actions_target  on public.admin_actions_log(target_type, target_id);

grant select on public.admin_actions_log to authenticated;
grant select, insert on public.admin_actions_log to service_role;

alter table public.admin_actions_log enable row level security;
-- Solo el admin de plataforma puede consultar los logs; el backend escribe con
-- service_role (que ignora RLS).
drop policy if exists admin_actions_select on public.admin_actions_log;
create policy admin_actions_select on public.admin_actions_log
  for select to authenticated
  using (public.is_platform_admin());

notify pgrst, 'reload schema';
