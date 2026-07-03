-- ============================================================================
-- 057_loop8_discounts_savings.sql   (Loop #8 · Iteración 1)
--
-- Base de datos para descuentos por gamificación/referidos basados en el PRECIO
-- REAL pagado por cada conductor, con validación de 15 días de los referidos y
-- contadores de ahorro para el jefe.
--
-- NOTA de arquitectura: el modelo actual es UNA suscripción por empresa
-- (Stripe per-seat, cantidad = nº de conductores). Estas tablas guardan el
-- histórico/valor de las recompensas; la materialización real (crédito Stripe
-- vs extensión) se decide en la Iteración 2. Aquí solo se crea el esquema.
--
-- Convenciones del repo: timestamptz, RLS por tenant, grants a authenticated +
-- service_role. Idempotente.
-- ============================================================================

-- 1.1 · Precio anual real pagado por cada conductor (por defecto 15 €, el precio
--      promocional con el cupón de lanzamiento). Se actualiza al cambiar de plan.
alter table public.users
  add column if not exists annual_price_paid numeric(10,2) not null default 15.00;

-- 1.2 · Histórico de extensiones de suscripción (auditoría + trazabilidad).
create table if not exists public.subscription_extensions (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references public.users(id)   on delete cascade on update cascade,
  tenant_id      uuid not null references public.tenants(id) on delete cascade on update cascade,
  extension_type varchar(20) not null check (extension_type in ('challenge', 'referral')),
  source_id      uuid,                    -- challenge_claim / referral_milestone_reward que lo generó
  days_extended  int not null,
  monthly_value  numeric(10,2) not null,  -- annual_price_paid / 12 en el momento de la extensión
  applied_at     timestamptz not null default now(),
  extended_until timestamptz not null
);
create index if not exists idx_subscription_extensions_user    on public.subscription_extensions(user_id);
create index if not exists idx_subscription_extensions_tenant  on public.subscription_extensions(tenant_id);
create index if not exists idx_subscription_extensions_applied on public.subscription_extensions(applied_at);

grant select on public.subscription_extensions to authenticated;
grant select, insert, update, delete on public.subscription_extensions to service_role;
alter table public.subscription_extensions enable row level security;
drop policy if exists subscription_extensions_select on public.subscription_extensions;
create policy subscription_extensions_select on public.subscription_extensions
  for select to authenticated
  using (
    user_id = auth.uid()
    or (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner')
  );

-- 1.3 · Ahorro mensual por empresa (para los contadores del jefe).
create table if not exists public.monthly_savings (
  id                     uuid primary key default gen_random_uuid(),
  tenant_id              uuid not null references public.tenants(id) on delete cascade on update cascade,
  year                   int not null,
  month                  int not null check (month between 1 and 12),
  savings_from_challenges numeric(10,2) not null default 0,
  savings_from_referrals  numeric(10,2) not null default 0,
  calculated_at          timestamptz not null default now(),
  unique (tenant_id, year, month)
);
create index if not exists idx_monthly_savings_tenant on public.monthly_savings(tenant_id, year, month);

grant select on public.monthly_savings to authenticated;
grant select, insert, update, delete on public.monthly_savings to service_role;
alter table public.monthly_savings enable row level security;
drop policy if exists monthly_savings_select on public.monthly_savings;
create policy monthly_savings_select on public.monthly_savings
  for select to authenticated
  using (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner');

-- 1.4 · Validación de 15 días de los referidos (desde el PRIMER PAGO).
alter table public.referrals
  add column if not exists first_payment_date timestamptz;
alter table public.referrals
  add column if not exists validation_status varchar(20) not null default 'pending'
    check (validation_status in ('pending', 'validated', 'rejected', 'expired'));
alter table public.referrals
  add column if not exists validation_date timestamptz;

-- 1.5 · Cola de validaciones asíncronas (la procesa el cron; solo backend).
create table if not exists public.referral_validation_queue (
  id            uuid primary key default gen_random_uuid(),
  referral_id   uuid not null references public.referrals(id) on delete cascade on update cascade,
  scheduled_for timestamptz not null,   -- first_payment_date + 15 días
  processed     boolean not null default false,
  created_at    timestamptz not null default now()
);
create index if not exists idx_referral_validation_queue_scheduled
  on public.referral_validation_queue(scheduled_for) where processed = false;

grant select, insert, update, delete on public.referral_validation_queue to service_role;
alter table public.referral_validation_queue enable row level security;
-- Sin política para authenticated: solo el backend (service_role) accede a la cola.

notify pgrst, 'reload schema';
