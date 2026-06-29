-- ============================================================================
-- 037_fraud_alerts.sql
-- Loop #5 — Centro de fraude del Super Admin (cross-domain).
--
-- Tabla genérica de alertas de fraude para dominios distintos de referidos
-- (p.ej. retos: km/€ manipulados). Las alertas de REFERIDOS siguen en
-- referral_fraud_alerts; el centro de fraude del dashboard unifica ambas en la
-- lectura. Solo crea estructura nueva. Aditivo, bajo riesgo, idempotente.
-- ============================================================================
create table if not exists public.fraud_alerts (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid references public.tenants(id) on delete cascade,
  user_id          uuid references public.users(id)   on delete set null,
  alert_type       text not null,                      -- p.ej. 'challenge_km_jump', 'challenge_under_300d'
  severity         text not null default 'medium' check (severity in ('low','medium','high')),
  description      text,
  evidence         jsonb,
  status           text not null default 'open' check (status in ('open','investigating','resolved')),
  resolution_notes text,
  resolved_by      uuid references public.users(id) on delete set null,
  resolved_at      timestamptz,
  created_at       timestamptz not null default now()
);
create index if not exists idx_fraud_alerts_status  on public.fraud_alerts(status, created_at desc);
create index if not exists idx_fraud_alerts_tenant  on public.fraud_alerts(tenant_id);
create index if not exists idx_fraud_alerts_type    on public.fraud_alerts(alert_type);

grant select on public.fraud_alerts to authenticated;
grant select, insert, update on public.fraud_alerts to service_role;

alter table public.fraud_alerts enable row level security;
-- Solo el admin de plataforma consulta; el backend escribe con service_role.
drop policy if exists fraud_alerts_select on public.fraud_alerts;
create policy fraud_alerts_select on public.fraud_alerts
  for select to authenticated
  using (public.is_platform_admin());

notify pgrst, 'reload schema';
