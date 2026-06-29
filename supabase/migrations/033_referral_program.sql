-- ============================================================
-- TaxiCount - Programa de referidos "Invita y Gana" (v2, por hitos).
--
-- REEMPLAZA el sistema simple anterior (migración 026). Para no perder datos,
-- la tabla vieja `referrals` se conserva renombrada como `referrals_legacy`.
-- El nuevo sistema:
--   - Código único por usuario ("TX" + 6 alfanuméricos) en referral_codes.
--   - Hitos escalonados (1/3/5/10/20 referidos válidos -> 7/14/30/60/180 días).
--   - El premio (días gratis) lo recibe la EMPRESA del referidor (tenant):
--     se aplicará extendiendo tenants.trial_ends_at desde el backend.
--   - Solo invitan empresarios/autónomos con suscripción activa de pago
--     (users.referral_eligible, que el backend recalcula).
--   - Anti-fraude: IP/dispositivo/emails temporales -> referral_fraud_alerts.
--   - Tope anual 360 días; reversión si el referido cancela en <15 días.
--
-- Esta migración es SOLO esquema + RLS (Iteración 1). Backend y app en las
-- siguientes iteraciones. Compatibilidad: el backend antiguo que consultaba
-- `referrals` queda envuelto en try/catch (no rompe el webhook); se sustituye
-- en la Iteración 3.
-- ============================================================

-- ---------- 0) Conservar el sistema viejo sin perder datos ----------
-- Renombra la tabla `referrals` ANTIGUA (la que tiene la columna rewarded_at) a
-- referrals_legacy, una sola vez. Guarda idempotente: si ya se hizo (o si la
-- tabla `referrals` ya es la nueva estructura), no hace nada. Así re-ejecutar
-- esta migración es seguro.
do $$
begin
  if exists (
        select 1 from information_schema.columns
         where table_schema = 'public' and table_name = 'referrals' and column_name = 'rewarded_at')
     and not exists (
        select 1 from information_schema.tables
         where table_schema = 'public' and table_name = 'referrals_legacy')
  then
    alter table public.referrals rename to referrals_legacy;
  end if;
end $$;
-- El RPC viejo se sustituye por el nuevo flujo (validate). Lo quitamos para no
-- insertar en una estructura que ya no es la canónica.
drop function if exists public.set_my_referrer(text);

-- ---------- 1) Configuración global (system_config) ----------
create table if not exists public.system_config (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);
grant select on public.system_config to authenticated, anon;
grant select, insert, update on public.system_config to service_role;
alter table public.system_config enable row level security;
-- Lectura pública de la config (no hay secretos aquí); escritura solo backend.
drop policy if exists system_config_read on public.system_config;
create policy system_config_read on public.system_config
  for select to anon, authenticated using (true);

insert into public.system_config(key, value) values
  ('referral_enabled',              'true'),
  ('referral_milestone_1_required', '1'),  ('referral_milestone_1_days', '7'),
  ('referral_milestone_2_required', '3'),  ('referral_milestone_2_days', '14'),
  ('referral_milestone_3_required', '5'),  ('referral_milestone_3_days', '30'),
  ('referral_milestone_4_required', '10'), ('referral_milestone_4_days', '60'),
  ('referral_milestone_5_required', '20'), ('referral_milestone_5_days', '180'),
  ('referral_annual_max_days',      '360'),
  ('referral_validation_days',      '30'),
  ('referral_max_shares_per_day',   '20'),
  ('referral_cancellation_grace_days', '15'),
  ('referral_max_per_ip_24h',       '3'),
  ('referral_email_domains_blocked', '')
on conflict (key) do nothing;

-- ---------- 2) Códigos de referido ----------
create table if not exists public.referral_codes (
  user_id    uuid primary key references public.users(id) on delete cascade,
  code       text not null,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index if not exists referral_codes_code_uidx on public.referral_codes (upper(code));

grant select, insert, update on public.referral_codes to authenticated, service_role;
alter table public.referral_codes enable row level security;
drop policy if exists referral_codes_select on public.referral_codes;
create policy referral_codes_select on public.referral_codes
  for select to authenticated using (user_id = auth.uid());

-- Genera un código "TX"+6 alfanuméricos (sin caracteres ambiguos) para un usuario.
create or replace function public.generate_referral_code()
returns text language sql volatile as $$
  select 'TX' || string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
           (floor(random()*32)::int)+1, 1), '')
  from generate_series(1, 6);
$$;

-- Sembrar códigos para los usuarios que ya existen (idempotente).
insert into public.referral_codes(user_id, code)
select u.id, public.generate_referral_code()
  from public.users u
 where not exists (select 1 from public.referral_codes rc where rc.user_id = u.id)
on conflict (user_id) do nothing;

-- ---------- 3) Referidos ----------
create table if not exists public.referrals (
  id                 uuid primary key default gen_random_uuid(),
  referrer_user_id   uuid not null references public.users(id)   on delete cascade,
  referred_user_id   uuid          references public.users(id)   on delete set null,
  referred_tenant_id uuid          references public.tenants(id) on delete set null,
  status             text not null default 'pending'
                     check (status in ('pending', 'valid', 'reverted', 'rejected')),
  signup_ip          text,
  signup_device_id   text,
  created_at         timestamptz not null default now(),
  validated_at       timestamptz,
  reverted_at        timestamptz
);
create index if not exists referrals_referrer_idx on public.referrals(referrer_user_id);
create index if not exists referrals_status_idx   on public.referrals(status);
create unique index if not exists referrals_referred_user_uidx
  on public.referrals(referred_user_id) where referred_user_id is not null;

grant select, insert, update on public.referrals to authenticated, service_role;
alter table public.referrals enable row level security;
-- El referidor ve sus referidos; el referido ve su propia fila.
drop policy if exists referrals_select on public.referrals;
create policy referrals_select on public.referrals
  for select to authenticated
  using (referrer_user_id = auth.uid() or referred_user_id = auth.uid());

-- ---------- 4) Hitos conseguidos (ledger por usuario) ----------
create table if not exists public.referral_milestone_rewards (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.users(id) on delete cascade,
  milestone_level int not null,                 -- 1..5
  required        int not null,                 -- nº de referidos exigidos
  days_awarded    int not null,                 -- días de premio concedidos
  awarded_at      timestamptz not null default now()
);
create unique index if not exists referral_milestone_user_lvl_uidx
  on public.referral_milestone_rewards(user_id, milestone_level);

grant select, insert on public.referral_milestone_rewards to authenticated, service_role;
alter table public.referral_milestone_rewards enable row level security;
drop policy if exists referral_milestone_select on public.referral_milestone_rewards;
create policy referral_milestone_select on public.referral_milestone_rewards
  for select to authenticated using (user_id = auth.uid());

-- ---------- 5) Comparticiones (para límite diario y métricas) ----------
create table if not exists public.referral_shares (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.users(id) on delete cascade,
  code       text not null,
  channel    text not null check (channel in ('whatsapp', 'email', 'sms', 'link', 'other')),
  created_at timestamptz not null default now()
);
create index if not exists referral_shares_user_day_idx on public.referral_shares(user_id, created_at);

grant select, insert on public.referral_shares to authenticated, service_role;
alter table public.referral_shares enable row level security;
drop policy if exists referral_shares_own on public.referral_shares;
create policy referral_shares_own on public.referral_shares
  for select to authenticated using (user_id = auth.uid());
drop policy if exists referral_shares_insert on public.referral_shares;
create policy referral_shares_insert on public.referral_shares
  for insert to authenticated with check (user_id = auth.uid());

-- ---------- 6) Alertas anti-fraude (solo admin vía backend) ----------
create table if not exists public.referral_fraud_alerts (
  id          uuid primary key default gen_random_uuid(),
  referral_id uuid references public.referrals(id) on delete cascade,
  type        text not null,   -- same_ip | ip_burst | temp_email | self_referral | device_dup
  severity    text not null default 'medium' check (severity in ('low', 'medium', 'high')),
  status      text not null default 'open' check (status in ('open', 'resolved', 'dismissed')),
  detail      jsonb,
  created_at  timestamptz not null default now(),
  resolved_at timestamptz
);
create index if not exists referral_fraud_status_idx on public.referral_fraud_alerts(status);

grant select, insert, update on public.referral_fraud_alerts to service_role;
alter table public.referral_fraud_alerts enable row level security;
-- Sin política para 'authenticated': los usuarios normales NO ven alertas.
-- El admin accede por el backend con service_role (que ignora RLS).

-- ---------- 7) Campos de referido en users ----------
alter table public.users
  add column if not exists referral_total_valid          int     not null default 0,
  add column if not exists referral_last_milestone_reached int   not null default 0,
  add column if not exists referral_rewards_annual_days   int     not null default 0,
  add column if not exists referral_annual_year           int     not null default extract(year from now())::int,
  add column if not exists referral_eligible              boolean not null default false;

notify pgrst, 'reload schema';
