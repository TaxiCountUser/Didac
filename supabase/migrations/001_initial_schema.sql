-- ============================================================
-- TaxiCount - Esquema inicial (Fase 0)
-- Tablas: tenants, users, vehicles, transactions
-- Multi-tenant con RLS (owner / driver).
-- ============================================================

-- Usamos gen_random_uuid() (core de Postgres 15), sin depender de
-- extensiones instaladas en el esquema "extensions".

-- ------------------------------------------------------------
-- Funciones auxiliares de auth (idempotentes).
-- supabase/postgres ya las trae; las (re)definimos por seguridad
-- para que el esquema sea autocontenido. No colisionan con GoTrue.
-- ------------------------------------------------------------
create schema if not exists auth;

create or replace function auth.uid()
returns uuid
language sql stable
as $$
  select nullif(current_setting('request.jwt.claims', true)::json ->> 'sub', '')::uuid
$$;

create or replace function auth.role()
returns text
language sql stable
as $$
  select nullif(current_setting('request.jwt.claims', true)::json ->> 'role', '')
$$;

-- ------------------------------------------------------------
-- Enums
-- ------------------------------------------------------------
do $$ begin
  create type user_role as enum ('owner', 'driver');
exception when duplicate_object then null; end $$;

do $$ begin
  create type transaction_type as enum ('income', 'expense');
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------
-- Tablas
-- ------------------------------------------------------------
create table if not exists public.tenants (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  created_at  timestamptz not null default now()
);

create table if not exists public.users (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade on update cascade,
  email         text not null unique,
  password_hash text,
  role          user_role not null default 'driver',
  created_at    timestamptz not null default now()
);

create table if not exists public.vehicles (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade on update cascade,
  license_plate text not null,
  model         text,
  created_at    timestamptz not null default now()
);

create table if not exists public.transactions (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants(id) on delete cascade on update cascade,
  user_id        uuid not null references public.users(id) on delete cascade on update cascade,
  vehicle_id     uuid references public.vehicles(id) on delete set null on update cascade,
  amount         decimal(12,2) not null,
  category       varchar(100),
  type           transaction_type not null,
  payment_method varchar(50),
  description    text,
  created_at     timestamptz not null default now()
);

create index if not exists idx_users_tenant on public.users(tenant_id);
create index if not exists idx_vehicles_tenant on public.vehicles(tenant_id);
create index if not exists idx_transactions_tenant on public.transactions(tenant_id);
create index if not exists idx_transactions_user on public.transactions(user_id);

-- ------------------------------------------------------------
-- Helpers SECURITY DEFINER: obtienen tenant/rol del usuario
-- autenticado SIN disparar RLS (evita recursión en políticas).
-- ------------------------------------------------------------
create or replace function public.current_tenant_id()
returns uuid
language sql stable security definer
set search_path = public
as $$
  select tenant_id from public.users where id = auth.uid()
$$;

create or replace function public.current_role_name()
returns text
language sql stable security definer
set search_path = public
as $$
  select role::text from public.users where id = auth.uid()
$$;

-- ------------------------------------------------------------
-- Privilegios para PostgREST (RLS sigue filtrando por fila)
-- ------------------------------------------------------------
grant usage on schema public to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema public to authenticated, service_role;
grant select on all tables in schema public to anon;
grant usage, select on all sequences in schema public to authenticated, service_role;
grant execute on all functions in schema public to anon, authenticated, service_role;

-- ------------------------------------------------------------
-- RLS
-- ------------------------------------------------------------
alter table public.tenants       enable row level security;
alter table public.users         enable row level security;
alter table public.vehicles      enable row level security;
alter table public.transactions  enable row level security;

-- tenants: cualquier autenticado del propio tenant puede verlo
drop policy if exists tenants_select on public.tenants;
create policy tenants_select on public.tenants
  for select to authenticated
  using (id = public.current_tenant_id());

-- users:
--   - cada usuario ve su propia fila
--   - un owner ve todas las filas de su tenant
drop policy if exists users_select on public.users;
create policy users_select on public.users
  for select to authenticated
  using (
    id = auth.uid()
    or (public.current_role_name() = 'owner' and tenant_id = public.current_tenant_id())
  );

drop policy if exists users_update_self on public.users;
create policy users_update_self on public.users
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- vehicles: todos los del propio tenant; owner además puede gestionar
drop policy if exists vehicles_select on public.vehicles;
create policy vehicles_select on public.vehicles
  for select to authenticated
  using (tenant_id = public.current_tenant_id());

drop policy if exists vehicles_owner_write on public.vehicles;
create policy vehicles_owner_write on public.vehicles
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner')
  with check (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner');

-- transactions:
--   - driver: solo ve/crea las suyas (de su tenant)
--   - owner: ve todas las de su tenant
drop policy if exists transactions_select on public.transactions;
create policy transactions_select on public.transactions
  for select to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (public.current_role_name() = 'owner' or user_id = auth.uid())
  );

drop policy if exists transactions_insert on public.transactions;
create policy transactions_insert on public.transactions
  for insert to authenticated
  with check (
    tenant_id = public.current_tenant_id()
    and user_id = auth.uid()
  );

drop policy if exists transactions_update_own on public.transactions;
create policy transactions_update_own on public.transactions
  for update to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (public.current_role_name() = 'owner' or user_id = auth.uid())
  )
  with check (tenant_id = public.current_tenant_id());
