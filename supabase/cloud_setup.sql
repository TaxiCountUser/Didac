-- ============================================================
-- TaxiCount - Esquema completo para Supabase Cloud (todas las migraciones).
-- Pega TODO esto en el SQL Editor de Supabase Cloud y ejecuta una vez.
-- NOTA: en Cloud, auth.uid()/auth.role() ya las provee Supabase, por eso
-- aqui NO se redefinen. No incluye el seed (datos de ejemplo).
-- ============================================================


-- ====== 001_initial_schema.sql ======
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
-- (P3-02) NO se concede SELECT global a anon: evita exponer una tabla futura sin
-- RLS. anon solo lee las tablas con grant explícito (system_config, etc.).
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

-- ====== 002_tenant_trigger.sql ======
-- ============================================================
-- TaxiCount - Fase 1
-- Tarea 2: creación automática de tenant + perfil al registrarse.
-- Tarea 8: campo de onboarding.
--
-- Al insertarse un usuario en auth.users:
--   - Si el metadata trae tenant_id  -> es un DRIVER invitado a un
--     tenant existente (lo crea el Owner vía service_role).
--   - Si NO trae tenant_id           -> es un OWNER nuevo: se crea un
--     tenant y su perfil con rol 'owner'.
-- ============================================================

-- Columnas nuevas en el perfil de usuario
alter table public.users add column if not exists name text;
alter table public.users add column if not exists has_completed_onboarding boolean not null default false;

-- Función del trigger (SECURITY DEFINER -> corre como owner, omite RLS)
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_meta      jsonb;
  v_tenant_id uuid;
  v_role      user_role;
begin
  v_meta := coalesce(NEW.raw_user_meta_data, '{}'::jsonb);

  if (v_meta ? 'tenant_id') and nullif(v_meta ->> 'tenant_id', '') is not null then
    -- Driver invitado a un tenant existente
    v_tenant_id := (v_meta ->> 'tenant_id')::uuid;
    v_role := coalesce(nullif(v_meta ->> 'role', ''), 'driver')::user_role;
  else
    -- Owner nuevo: crear su tenant
    v_role := 'owner';
    insert into public.tenants (name)
    values (coalesce(nullif(v_meta ->> 'company_name', ''), split_part(NEW.email, '@', 1)))
    returning id into v_tenant_id;
  end if;

  insert into public.users (id, tenant_id, email, name, role)
  values (NEW.id, v_tenant_id, NEW.email, nullif(v_meta ->> 'name', ''), v_role)
  on conflict (id) do nothing;

  return NEW;
end;
$$;

-- (Re)crear el trigger en auth.users
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- ====== 003_rls_refinement.sql ======
-- ============================================================
-- TaxiCount - Fase 1
-- Tarea 7: refinamiento de políticas RLS.
--
--   users        : self + Owner ve todo su tenant            (sin cambios)
--   vehicles     : SOLO Owners (leer y gestionar). Drivers NO leen.
--   transactions : Owner lee las de su tenant. Inserción de
--                  clientes deshabilitada (se habilita en Fase 2);
--                  service_role la sigue pudiendo hacer (bypass RLS).
-- ============================================================

-- ---------- vehicles: solo Owner del tenant ----------
drop policy if exists vehicles_select on public.vehicles;
create policy vehicles_select on public.vehicles
  for select to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and public.current_role_name() = 'owner'
  );

-- (vehicles_owner_write ya existe en 001: ALL solo para owner del tenant)

-- ---------- transactions: lectura del Owner; sin insert/update de cliente ----------
drop policy if exists transactions_select on public.transactions;
create policy transactions_select on public.transactions
  for select to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (public.current_role_name() = 'owner' or user_id = auth.uid())
  );

-- Inserción/actualización por clientes deshabilitada en Fase 1
-- (no hay política -> denegado para authenticated; service_role hace bypass).
drop policy if exists transactions_insert on public.transactions;
drop policy if exists transactions_update_own on public.transactions;

-- ====== 004_transactions_input.sql ======
-- ============================================================
-- TaxiCount - Fase 2
-- Habilita la entrada de transacciones (manual + voz) y el
-- contador diario de transcripciones por usuario.
-- ============================================================

-- ---------- transactions: el driver/owner inserta las suyas ----------
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

-- ---------- contador diario de transcripciones (Tarea 7) ----------
alter table public.users
  add column if not exists daily_transcription_count integer not null default 0;
alter table public.users
  add column if not exists transcription_count_date date;

-- ====== 005_indexes.sql ======
-- ============================================================
-- TaxiCount - Fase 3 (DashboardSyncLoop)
-- Índices para las consultas frecuentes del dashboard:
--   - listado/paginación por tenant ordenado por fecha
--   - historial del driver ordenado por fecha
-- (idx_transactions_tenant e idx_transactions_user ya existen en 001;
--  aquí añadimos los que faltan para ORDER BY created_at eficiente.)
-- ============================================================

-- Orden descendente por fecha dentro de un tenant (dashboard del Owner).
create index if not exists idx_transactions_tenant_created
  on public.transactions (tenant_id, created_at desc);

-- Orden descendente por fecha de un usuario (historial del Driver).
create index if not exists idx_transactions_user_created
  on public.transactions (user_id, created_at desc);

-- Índice plano por fecha (filtros de periodo globales).
create index if not exists idx_transactions_created
  on public.transactions (created_at desc);

-- ---------- Realtime: esquemas del servidor (opcional) ----------
-- El servicio supabase/realtime migra en _realtime (repo principal) y en
-- realtime (extensión CDC por tenant); ambos deben existir de antemano.
create schema if not exists _realtime;
create schema if not exists realtime;

-- ---------- Realtime: publicar la tabla transactions (Tarea 4) ----------
do $$ begin
  alter publication supabase_realtime add table public.transactions;
exception
  when duplicate_object then null;  -- ya está en la publicación
  when undefined_object then null;  -- la publicación no existe en este stack
end $$;

-- ---------- transactions: política DELETE (Tarea 6) ----------
-- Owner: cualquiera de su tenant. Driver: solo las suyas.
drop policy if exists transactions_delete on public.transactions;
create policy transactions_delete on public.transactions
  for delete to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (public.current_role_name() = 'owner' or user_id = auth.uid())
  );

-- ====== 006_tenant_billing.sql ======
-- ============================================================
-- TaxiCount - Fase 4 (SubscriptionBillingLoop)
-- Monetización con Stripe: datos de suscripción en `tenants`,
-- límite de conductores por plan y bloqueo de escritura por impago.
--
-- NOTA de numeración: la especificación la llama "004_tenant_billing"
-- pero 004 ya existe (transactions_input); usamos el siguiente libre.
-- ============================================================

-- ---------- Columnas de facturación en tenants ----------
alter table public.tenants
  add column if not exists stripe_customer_id     text,
  add column if not exists stripe_subscription_id text,
  -- trialing | active | past_due | canceled | inactive
  add column if not exists subscription_status    text not null default 'trialing',
  add column if not exists plan_id                 text,
  -- NULL = ilimitado (plan Business o periodo de prueba)
  add column if not exists drivers_limit           integer;

-- ---------- Helper: ¿la suscripción del tenant permite escribir? ----------
-- SECURITY DEFINER para leer tenants sin disparar RLS (igual patrón que los
-- otros helpers). Activa con 'active' o 'trialing'.
create or replace function public.current_subscription_active()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select coalesce(
    (select subscription_status in ('active', 'trialing')
       from public.tenants
      where id = public.current_tenant_id()),
    false)
$$;

grant execute on function public.current_subscription_active() to anon, authenticated, service_role;

-- ---------- transactions: añadir el bloqueo por suscripción ----------
-- Se re-crean las políticas de escritura (insert/update/delete) para exigir
-- además una suscripción activa. La lectura NO se bloquea (el Owner debe
-- poder consultar su histórico aunque esté impagado).

drop policy if exists transactions_insert on public.transactions;
create policy transactions_insert on public.transactions
  for insert to authenticated
  with check (
    tenant_id = public.current_tenant_id()
    and user_id = auth.uid()
    and public.current_subscription_active()
  );

drop policy if exists transactions_update_own on public.transactions;
create policy transactions_update_own on public.transactions
  for update to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (public.current_role_name() = 'owner' or user_id = auth.uid())
  )
  with check (
    tenant_id = public.current_tenant_id()
    and public.current_subscription_active()
  );

drop policy if exists transactions_delete on public.transactions;
create policy transactions_delete on public.transactions
  for delete to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (public.current_role_name() = 'owner' or user_id = auth.uid())
    and public.current_subscription_active()
  );

-- ====== 007_carrera_fields.sql ======
-- ============================================================
-- TaxiCount - Carreras: metadatos extra para los ingresos.
--
-- Una "carrera" es una transacción de tipo income con datos
-- adicionales que el conductor apunta para llevar un registro
-- detallado (útil p. ej. ante consultas/investigaciones) y para
-- que el propietario controle los km diarios del coche.
--
--   origin        origen del viaje (texto libre, opcional)
--   destination   destino del viaje (texto libre, opcional)
--   odometer_km   km del coche en ese momento (opcional)
--   client_name   empresa/cliente; vacío/NULL => cliente particular
--
-- La "hora" del viaje es created_at (ya existente). Los gastos
-- (type = expense) no usan estos campos.
-- ============================================================

alter table public.transactions
  add column if not exists origin       text,
  add column if not exists destination  text,
  add column if not exists odometer_km  integer,
  add column if not exists client_name  text;

-- Búsqueda/filtrado por empresa (case-insensitive) en informes.
create index if not exists idx_transactions_client_name
  on public.transactions (lower(client_name));

-- El odómetro, si se informa, no puede ser negativo.
alter table public.transactions
  drop constraint if exists transactions_odometer_km_nonneg;
alter table public.transactions
  add constraint transactions_odometer_km_nonneg
  check (odometer_km is null or odometer_km >= 0);

-- ====== 008_driver_vehicles.sql ======
-- ============================================================
-- TaxiCount - Asignación conductor <-> vehículo (M:N).
--
-- El Owner decide a qué vehículos puede acceder cada conductor:
--   - desde un coche, asignarle uno o varios choferes;
--   - desde un chofer, asignarle uno o varios coches.
-- Si un conductor tiene 1 vehículo, la app lo usa automáticamente; si
-- tiene varios, elige cuál al registrar (o al empezar el día).
-- Esto permite imputar gastos/carreras y km a cada coche con exactitud.
-- ============================================================

create table if not exists public.driver_vehicles (
  tenant_id  uuid not null references public.tenants(id)  on delete cascade on update cascade,
  user_id    uuid not null references public.users(id)    on delete cascade on update cascade,
  vehicle_id uuid not null references public.vehicles(id) on delete cascade on update cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, vehicle_id)
);

create index if not exists idx_driver_vehicles_tenant  on public.driver_vehicles(tenant_id);
create index if not exists idx_driver_vehicles_user    on public.driver_vehicles(user_id);
create index if not exists idx_driver_vehicles_vehicle on public.driver_vehicles(vehicle_id);

-- Privilegios (tabla nueva: el grant global de 001 no la cubre).
grant select, insert, update, delete on public.driver_vehicles to authenticated, service_role;
grant select on public.driver_vehicles to anon;

alter table public.driver_vehicles enable row level security;

-- SELECT: el owner ve todas las de su tenant; el driver, solo las suyas.
drop policy if exists driver_vehicles_select on public.driver_vehicles;
create policy driver_vehicles_select on public.driver_vehicles
  for select to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (public.current_role_name() = 'owner' or user_id = auth.uid())
  );

-- WRITE (insert/update/delete): solo el owner, dentro de su tenant.
drop policy if exists driver_vehicles_owner_write on public.driver_vehicles;
create policy driver_vehicles_owner_write on public.driver_vehicles
  for all to authenticated
  using (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner')
  with check (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner');

-- ====== 009_odometer_readings.sql ======
-- ============================================================
-- TaxiCount - Lecturas de odómetro (km diarios por vehículo).
--
-- Al empezar el día, el conductor apunta los km del coche activo
-- (prerellenados con los últimos conocidos). Sirve para que el
-- propietario sepa los km diarios de cada vehículo. Si el conductor
-- no contesta, se siguen usando los últimos km apuntados.
-- ============================================================

create table if not exists public.odometer_readings (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id)  on delete cascade on update cascade,
  vehicle_id  uuid not null references public.vehicles(id) on delete cascade on update cascade,
  user_id     uuid not null references public.users(id)    on delete cascade on update cascade,
  reading_km  integer not null check (reading_km >= 0),
  taken_at    timestamptz not null default now(),
  created_at  timestamptz not null default now()
);

create index if not exists idx_odometer_tenant         on public.odometer_readings(tenant_id);
create index if not exists idx_odometer_vehicle_taken  on public.odometer_readings(vehicle_id, taken_at desc);

-- Privilegios (tabla nueva: el grant global de 001 no la cubre).
grant select, insert, update, delete on public.odometer_readings to authenticated, service_role;
grant select on public.odometer_readings to anon;

alter table public.odometer_readings enable row level security;

-- SELECT: el owner ve las de su tenant; el driver, las suyas.
drop policy if exists odometer_select on public.odometer_readings;
create policy odometer_select on public.odometer_readings
  for select to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (public.current_role_name() = 'owner' or user_id = auth.uid())
  );

-- INSERT: el conductor apunta las suyas (de su tenant).
drop policy if exists odometer_insert on public.odometer_readings;
create policy odometer_insert on public.odometer_readings
  for insert to authenticated
  with check (
    tenant_id = public.current_tenant_id()
    and user_id = auth.uid()
  );

-- ====== 010_incidents.sql ======
-- ============================================================
-- TaxiCount - Incidencias / notas al jefe.
--
-- Dos usos en una sola tabla (campo kind):
--   'nota' -> mensaje del conductor al jefe (p. ej. "ruido en la rueda
--             derecha"). El Owner las ve en su panel de Incidencias.
--   'app'  -> reporte de un fallo de la app (ticket).
-- El Owner puede marcarlas como resueltas.
-- ============================================================

create table if not exists public.incidents (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade on update cascade,
  user_id     uuid not null references public.users(id)   on delete cascade on update cascade,
  kind        text not null default 'nota' check (kind in ('nota', 'app')),
  body        text not null check (length(btrim(body)) > 0),
  status      text not null default 'abierta' check (status in ('abierta', 'resuelta')),
  created_at  timestamptz not null default now()
);

create index if not exists idx_incidents_tenant on public.incidents(tenant_id, created_at desc);
create index if not exists idx_incidents_user   on public.incidents(user_id);

grant select, insert, update, delete on public.incidents to authenticated, service_role;
grant select on public.incidents to anon;

alter table public.incidents enable row level security;

-- SELECT: el owner ve las de su tenant; el autor (conductor) ve las suyas.
drop policy if exists incidents_select on public.incidents;
create policy incidents_select on public.incidents
  for select to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (public.current_role_name() = 'owner' or user_id = auth.uid())
  );

-- INSERT: cualquier autenticado crea las suyas (de su tenant).
drop policy if exists incidents_insert on public.incidents;
create policy incidents_insert on public.incidents
  for insert to authenticated
  with check (
    tenant_id = public.current_tenant_id()
    and user_id = auth.uid()
  );

-- UPDATE: el owner gestiona el estado (resuelta) dentro de su tenant.
drop policy if exists incidents_owner_update on public.incidents;
create policy incidents_owner_update on public.incidents
  for update to authenticated
  using (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner')
  with check (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner');

-- ====== 011_user_display_name.sql ======
-- ============================================================
-- TaxiCount - Nombre "de avatar" del conductor.
--
-- `name` lo pone el jefe (lo ve en SU panel y no cambia). `display_name` es
-- opcional y lo elige el propio conductor para mostrarse en SU app. Si está
-- vacío, la app del conductor usa `name`.
-- ============================================================

alter table public.users
  add column if not exists display_name text;

-- ====== 012_driver_locations.sql ======
-- ============================================================
-- TaxiCount - Última ubicación conocida del conductor (localizar vehículo).
--
-- Una fila por conductor (PK = user_id): se sobreescribe (upsert) con su
-- posición más reciente. El jefe la ve en "Localizar vehículo".
-- Privacidad: el conductor comparte su ubicación con permiso del dispositivo;
-- solo la ve el Owner de su propia flota.
-- ============================================================

create table if not exists public.driver_locations (
  user_id    uuid primary key references public.users(id)   on delete cascade on update cascade,
  tenant_id  uuid not null      references public.tenants(id) on delete cascade on update cascade,
  lat        double precision not null,
  lng        double precision not null,
  accuracy   double precision,
  updated_at timestamptz not null default now()
);

create index if not exists idx_driver_locations_tenant on public.driver_locations(tenant_id);

grant select, insert, update, delete on public.driver_locations to authenticated, service_role;
grant select on public.driver_locations to anon;

alter table public.driver_locations enable row level security;

-- SELECT: el owner ve las de su tenant; el conductor, la suya.
drop policy if exists driver_locations_select on public.driver_locations;
create policy driver_locations_select on public.driver_locations
  for select to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (public.current_role_name() = 'owner' or user_id = auth.uid())
  );

-- INSERT/UPDATE: el conductor escribe SOLO la suya (de su tenant).
drop policy if exists driver_locations_insert on public.driver_locations;
create policy driver_locations_insert on public.driver_locations
  for insert to authenticated
  with check (tenant_id = public.current_tenant_id() and user_id = auth.uid());

drop policy if exists driver_locations_update on public.driver_locations;
create policy driver_locations_update on public.driver_locations
  for update to authenticated
  using (tenant_id = public.current_tenant_id() and user_id = auth.uid())
  with check (tenant_id = public.current_tenant_id() and user_id = auth.uid());

-- ====== 013_user_license.sql ======
-- ============================================================
-- TaxiCount - Número de licencia del conductor.
-- Lo edita el propio conductor en su app (RLS users_update_self).
-- ============================================================

alter table public.users
  add column if not exists license_number text;

-- ====== 014_driver_reads_assigned_vehicles.sql ======
-- ============================================================
-- TaxiCount - El chofer puede LEER los vehículos que el jefe le ha asignado.
--
-- Problema: 003 dejó vehicles.select SOLO para owners. Por eso, cuando la app
-- del chofer hace el join driver_vehicles -> vehicles (para elegir coche en
-- Ajustes / al empezar el día), RLS bloquea la fila de vehicles y el embed
-- devuelve null => el selector sale vacío aunque el jefe ya haya asignado coche.
--
-- Solución: el owner sigue viendo todos los vehículos de su tenant; el chofer
-- puede leer únicamente los vehículos vinculados a él en driver_vehicles.
-- No le damos write: la asignación la sigue gestionando solo el owner.
-- ============================================================

drop policy if exists vehicles_select on public.vehicles;
create policy vehicles_select on public.vehicles
  for select to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (
      public.current_role_name() = 'owner'
      or exists (
        select 1
        from public.driver_vehicles dv
        where dv.vehicle_id = public.vehicles.id
          and dv.user_id = auth.uid()
      )
    )
  );

-- ====== 015_vehicle_maintenance.sql ======
-- ============================================================
-- TaxiCount - Ficha de mantenimiento por vehículo (solo panel del jefe).
--
-- El jefe quiere controlar, por coche, el estado de:
--   - ITV         : próxima fecha de inspección.
--   - Seguro      : próxima fecha de renovación.
--   - Tarjeta de transporte: fecha del último visado/renovación + periodo
--                   (en España el visado periódico se suprimió en 2019; se deja
--                   el periodo configurable, por defecto 4 años, por si el
--                   operador quiere seguir avisándose).
--   - Revisiones  : intervalo en km + km del coche en la última revisión
--                   (para calcular cuántos km quedan hasta la siguiente).
--
-- Los km "actuales" del coche NO se guardan aquí: se derivan de odometer_readings
-- / transactions (lastOdometer). Aquí solo guardamos la configuración/fechas.
-- Solo el owner gestiona estos campos (RLS de vehicles ya lo cubre: write owner).
-- ============================================================

alter table public.vehicles
  add column if not exists itv_expiry              date,
  add column if not exists insurance_expiry        date,
  add column if not exists transport_card_date     date,
  add column if not exists transport_card_years    int  not null default 4,
  add column if not exists revision_interval_km    int  not null default 15000,
  add column if not exists last_revision_km        int,
  add column if not exists maintenance_notes        text,
  add column if not exists taximeter_itv_expiry    date,   -- punto 6: ITV del taxímetro
  add column if not exists registered_km           int;    -- punto 7: km al dar de alta

-- Recarga el esquema en PostgREST tras aplicar.

-- ====== 016_tenant_name_update.sql ======
-- ============================================================
-- TaxiCount - El Owner puede editar el NOMBRE de su empresa.
--
-- Antes no había política UPDATE en tenants, así que el nombre no se podía
-- cambiar. Permitimos a un owner actualizar SOLO su tenant, y a nivel de
-- columna restringimos a `name` (los campos de facturación —subscription_status,
-- plan_id, drivers_limit, stripe_*— solo los toca service_role vía webhook).
-- ============================================================

-- Privilegio de columna: authenticated solo puede actualizar `name`.
revoke update on public.tenants from authenticated;
grant update (name) on public.tenants to authenticated;
-- service_role conserva update completo (bypassa RLS igualmente).
grant update on public.tenants to service_role;

drop policy if exists tenants_owner_update on public.tenants;
create policy tenants_owner_update on public.tenants
  for update to authenticated
  using (id = public.current_tenant_id() and public.current_role_name() = 'owner')
  with check (id = public.current_tenant_id() and public.current_role_name() = 'owner');

-- ====== 017_incidents_delete_cleanup.sql ======
-- ============================================================
-- TaxiCount - Borrado de incidencias + autolimpieza.
--   - El Owner puede ELIMINAR incidencias de su flota.
--   - Autolimpieza: una función borra las de más de 90 días del tenant actual
--     (se llama desde la app al abrir el panel; no requiere pg_cron).
-- ============================================================

drop policy if exists incidents_owner_delete on public.incidents;
create policy incidents_owner_delete on public.incidents
  for delete to authenticated
  using (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner');

-- Borra incidencias de más de 90 días del tenant del que llama. SECURITY DEFINER
-- para poder limpiar en bloque, pero acotado a current_tenant_id().
create or replace function public.cleanup_old_incidents()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare n integer;
begin
  delete from public.incidents
   where tenant_id = public.current_tenant_id()
     and created_at < now() - interval '90 days';
  get diagnostics n = row_count;
  return n;
end;
$$;

grant execute on function public.cleanup_old_incidents() to authenticated;

-- ====== 018_incident_messages.sql ======
-- ============================================================
-- TaxiCount - Chat por incidencia (jefe <-> conductor).
-- Ambas partes pueden escribir MIENTRAS la incidencia no esté 'resuelta'.
-- Al marcarla resuelta, deja de poder escribirse (RLS de insert lo impide).
-- ============================================================

create table if not exists public.incident_messages (
  id          uuid primary key default gen_random_uuid(),
  incident_id uuid not null references public.incidents(id) on delete cascade,
  tenant_id   uuid not null references public.tenants(id)   on delete cascade,
  user_id     uuid not null references public.users(id)     on delete cascade,
  body        text not null,
  created_at  timestamptz not null default now()
);
create index if not exists idx_incident_messages_incident
  on public.incident_messages(incident_id, created_at);

grant select, insert, delete on public.incident_messages to authenticated, service_role;

alter table public.incident_messages enable row level security;

-- SELECT: el owner del tenant, o el autor de la incidencia.
drop policy if exists incident_messages_select on public.incident_messages;
create policy incident_messages_select on public.incident_messages
  for select to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (
      public.current_role_name() = 'owner'
      or exists (select 1 from public.incidents i
                 where i.id = incident_id and i.user_id = auth.uid())
    )
  );

-- INSERT: owner o autor, solo si la incidencia NO está resuelta.
drop policy if exists incident_messages_insert on public.incident_messages;
create policy incident_messages_insert on public.incident_messages
  for insert to authenticated
  with check (
    tenant_id = public.current_tenant_id()
    and user_id = auth.uid()
    and exists (
      select 1 from public.incidents i
      where i.id = incident_id
        and i.status <> 'resuelta'
        and (public.current_role_name() = 'owner' or i.user_id = auth.uid())
    )
  );

-- DELETE: solo el owner del tenant (limpieza).
drop policy if exists incident_messages_owner_delete on public.incident_messages;
create policy incident_messages_owner_delete on public.incident_messages
  for delete to authenticated
  using (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner');

-- ====== 019_user_avatar.sql ======
-- TaxiCount - Avatar del usuario (foto en base64 o null = icono).
alter table public.users add column if not exists avatar_url text;

-- ====== 020_owner_edit_driver.sql ======
-- ============================================================
-- TaxiCount - El Owner puede editar el NOMBRE de un conductor de su flota.
-- Vía RPC SECURITY DEFINER (comprueba que es owner del mismo tenant).
-- El correo de acceso NO se cambia aquí (es de auth; requiere admin API).
-- ============================================================
create or replace function public.owner_set_driver_name(p_driver uuid, p_name text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.current_role_name() <> 'owner' then
    raise exception 'Solo el owner puede editar conductores';
  end if;
  update public.users
     set name = nullif(btrim(p_name), '')
   where id = p_driver
     and tenant_id = public.current_tenant_id()
     and role = 'driver';
end;
$$;
grant execute on function public.owner_set_driver_name(uuid, text) to authenticated;

-- ====== 021_username_login.sql ======
-- ============================================================
-- TaxiCount - Inicio de sesión con nombre de usuario (además del correo).
-- Supabase autentica por correo; aquí guardamos un username único y, al entrar,
-- la app traduce username -> email vía email_for_username() y luego hace login.
-- ============================================================
alter table public.users add column if not exists username text;
create unique index if not exists users_username_lower_uidx
  on public.users (lower(username)) where username is not null;

-- Devuelve el correo asociado a un username (para poder iniciar sesión con él).
-- Callable por anon (aún sin sesión). Solo expone el email en coincidencia exacta.
create or replace function public.email_for_username(p_username text)
returns text
language sql
security definer
set search_path = public
stable
as $$
  select email from public.users
   where lower(username) = lower(btrim(p_username))
   limit 1;
$$;
-- (P3-01) El email ya NO se resuelve por RPC: el backend (/auth/login-username)
-- hace el login con usuario y nunca expone el email. Revocamos el execute (el
-- grant global de funciones de más arriba incluye anon, por eso es explícito).
revoke execute on function public.email_for_username(text) from anon, authenticated;

-- ============================================================
-- TaxiCount - "Sacar de la flota" (despedir/desactivar conductor).
-- Un conductor con active=false queda FUERA de la flota: no puede leer ni
-- escribir ningún dato del tenant (carreras, incidencias, ubicación...). En la
-- app solo ve la pantalla "no tienes ninguna flota activa".
--
-- Mecanismo: current_tenant_id() devuelve NULL para un usuario inactivo, así
-- todas las políticas RLS que comparan con current_tenant_id() cierran en
-- falso. La fila propia sigue siendo legible (users_select: id = auth.uid())
-- para que la app pueda detectar el estado y mostrar la pantalla de bloqueo.
-- ============================================================
alter table public.users add column if not exists active boolean not null default true;

create or replace function public.current_tenant_id()
returns uuid
language sql stable security definer
set search_path = public
as $$
  select tenant_id from public.users where id = auth.uid() and active is true
$$;

notify pgrst, 'reload schema';

-- ============================================================
-- TaxiCount - Alta diferida + unirse a una flota con código.
--
-- Antes: cualquier alta por OAuth (Google) sin metadata se convertía en un
-- Owner con empresa vacía. Ahora queda PENDIENTE (sin flota) y la app le ofrece
-- elegir: crear su empresa (propietario) o unirse a una flota con un código que
-- el jefe comparte. Los conductores que el jefe da de alta por correo siguen
-- vinculándose solos (su identidad de Google enlaza a su cuenta confirmada).
-- ============================================================

-- 1) tenant_id pasa a ser OPCIONAL: un usuario recién creado sin flota queda
--    "pendiente" hasta que elige crear empresa o unirse a una.
alter table public.users alter column tenant_id drop not null;

-- 2) Código de flota: corto y único; el jefe lo comparte con sus trabajadores.
alter table public.tenants add column if not exists join_code text;
update public.tenants
   set join_code = upper(substr(md5(random()::text || id::text || clock_timestamp()::text), 1, 6))
 where join_code is null;
create unique index if not exists tenants_join_code_uidx on public.tenants(join_code);

-- 3) Trigger de alta: OAuth/sin metadata => usuario SIN flota (pendiente).
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_meta      jsonb;
  v_tenant_id uuid;
  v_role      user_role;
begin
  v_meta := coalesce(NEW.raw_user_meta_data, '{}'::jsonb);

  if (v_meta ? 'tenant_id') and nullif(v_meta ->> 'tenant_id', '') is not null then
    -- Driver invitado a un tenant existente (lo crea el Owner vía service_role).
    v_tenant_id := (v_meta ->> 'tenant_id')::uuid;
    v_role := coalesce(nullif(v_meta ->> 'role', ''), 'driver')::user_role;
    insert into public.users (id, tenant_id, email, name, role)
    values (NEW.id, v_tenant_id, NEW.email, nullif(v_meta ->> 'name', ''), v_role)
    on conflict (id) do nothing;

  elsif nullif(v_meta ->> 'company_name', '') is not null then
    -- Alta explícita de Owner (registro con nombre de empresa): crea su tenant.
    insert into public.tenants (name, join_code)
    values (
      v_meta ->> 'company_name',
      upper(substr(md5(random()::text || NEW.id::text || clock_timestamp()::text), 1, 6))
    )
    returning id into v_tenant_id;
    insert into public.users (id, tenant_id, email, name, role)
    values (NEW.id, v_tenant_id, NEW.email, nullif(v_meta ->> 'name', ''), 'owner')
    on conflict (id) do nothing;

  else
    -- Alta por OAuth (Google) sin datos: PENDIENTE, sin flota. La app le pedirá
    -- crear empresa o unirse a una con un código.
    insert into public.users (id, tenant_id, email, name, role)
    values (NEW.id, null, NEW.email, null, 'driver')
    on conflict (id) do nothing;
  end if;

  return NEW;
end;
$$;

-- 4) RPC: crear mi empresa (para un usuario pendiente -> pasa a Owner).
create or replace function public.create_owner_company(p_name text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_existing uuid;
  v_tenant   uuid;
begin
  if v_uid is null then raise exception 'No autenticado'; end if;
  select tenant_id into v_existing from public.users where id = v_uid;
  if v_existing is not null then raise exception 'Ya perteneces a una flota'; end if;

  insert into public.tenants (name, join_code)
  values (
    coalesce(nullif(btrim(p_name), ''), 'Mi empresa'),
    upper(substr(md5(random()::text || v_uid::text || clock_timestamp()::text), 1, 6))
  )
  returning id into v_tenant;

  update public.users
     set tenant_id = v_tenant, role = 'owner', active = true
   where id = v_uid;
  return v_tenant;
end;
$$;

-- 5) RPC: unirse a una flota con código (para un usuario pendiente -> Driver).
create or replace function public.join_fleet_with_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_existing uuid;
  v_tenant   uuid;
  v_name     text;
  v_limit    int;
  v_count    int;
begin
  if v_uid is null then raise exception 'No autenticado'; end if;
  select tenant_id into v_existing from public.users where id = v_uid;
  if v_existing is not null then raise exception 'Ya perteneces a una flota'; end if;

  select id, name, drivers_limit
    into v_tenant, v_name, v_limit
    from public.tenants
   where upper(join_code) = upper(btrim(p_code));
  if v_tenant is null then raise exception 'Código no válido'; end if;

  if v_limit is not null then
    select count(*) into v_count
      from public.users where tenant_id = v_tenant and role = 'driver';
    if v_count >= v_limit then
      raise exception 'La flota ha alcanzado su límite de conductores';
    end if;
  end if;

  update public.users
     set tenant_id = v_tenant, role = 'driver', active = true
   where id = v_uid;
  return jsonb_build_object('tenant_id', v_tenant, 'name', v_name);
end;
$$;

grant execute on function public.create_owner_company(text) to authenticated;
grant execute on function public.join_fleet_with_code(text) to authenticated;

notify pgrst, 'reload schema';

-- ============================================================
-- TaxiCount - Tokens de dispositivo para notificaciones push (FCM).
-- Cada usuario guarda el/los token(s) FCM de sus dispositivos. El backend
-- (service_role) los lee para enviar el push cuando hay una incidencia nueva o
-- un mensaje nuevo en el chat de una incidencia.
-- ============================================================
create table if not exists public.device_tokens (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.users(id) on delete cascade on update cascade,
  tenant_id   uuid references public.tenants(id) on delete cascade on update cascade,
  token       text not null unique,
  platform    text,
  updated_at  timestamptz not null default now()
);

create index if not exists idx_device_tokens_user   on public.device_tokens(user_id);
create index if not exists idx_device_tokens_tenant on public.device_tokens(tenant_id);

grant select, insert, update, delete on public.device_tokens to authenticated, service_role;

alter table public.device_tokens enable row level security;

-- Cada usuario gestiona únicamente sus propios tokens.
drop policy if exists device_tokens_self on public.device_tokens;
create policy device_tokens_self on public.device_tokens
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

notify pgrst, 'reload schema';


-- ============================================================
-- TaxiCount - Prueba de 15 días + modo autónomo + admin global.
--
-- 1) Prueba gratis de 15 días: cada tenant nuevo puede usar la app 15 días sin
--    tarjeta. Al caducar, si no hay suscripción activa, la escritura se bloquea
--    (las políticas RLS ya exigen current_subscription_active()).
-- 2) Modo autónomo (solo=true): el dueño es también su propio chófer; sin GPS y
--    solo plan Starter. A nivel de datos sigue siendo un 'owner' (ya puede crear
--    sus propias transacciones), la app le ofrece un conmutador Empresa/Chófer.
-- 3) Admin global (is_admin): ve y resuelve incidencias de TODAS las empresas.
--    El acceso real va por el backend con service_role; aquí solo guardamos la
--    marca y sembramos al admin principal.
-- ============================================================

-- ---------- 1) Prueba de 15 días ----------
alter table public.tenants
  add column if not exists trial_ends_at timestamptz;

-- Tenants existentes: 15 días desde su creación (los muy antiguos quedarán ya
-- caducados, lo cual es correcto: deben suscribirse).
update public.tenants
   set trial_ends_at = created_at + interval '15 days'
 where trial_ends_at is null;

-- A partir de ahora, por defecto 15 días desde el alta.
alter table public.tenants
  alter column trial_ends_at set default (now() + interval '15 days');

-- La suscripción "permite escribir" si está activa/al día, o si sigue dentro de
-- la prueba de 15 días.
create or replace function public.current_subscription_active()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select coalesce(
    (select
        subscription_status in ('active', 'past_due')  -- 'past_due' = margen de cortesía
        or (subscription_status = 'trialing' and now() < coalesce(trial_ends_at, now()))
        or now() < coalesce(trial_ends_at, 'epoch'::timestamptz)
       from public.tenants
      where id = public.current_tenant_id()),
    false)
$$;

grant execute on function public.current_subscription_active() to anon, authenticated, service_role;

-- ---------- 2) Modo autónomo ----------
alter table public.tenants
  add column if not exists solo boolean not null default false;

-- RPC: crear mi empresa en modo autónomo (soy empresa y chófer a la vez).
create or replace function public.create_solo_company(p_name text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_existing uuid;
  v_tenant   uuid;
begin
  if v_uid is null then raise exception 'No autenticado'; end if;
  select tenant_id into v_existing from public.users where id = v_uid;
  if v_existing is not null then raise exception 'Ya perteneces a una flota'; end if;

  insert into public.tenants (name, join_code, solo)
  values (
    coalesce(nullif(btrim(p_name), ''), 'Mi taxi'),
    upper(substr(md5(random()::text || v_uid::text || clock_timestamp()::text), 1, 6)),
    true
  )
  returning id into v_tenant;

  update public.users
     set tenant_id = v_tenant, role = 'owner', active = true
   where id = v_uid;
  return v_tenant;
end;
$$;

grant execute on function public.create_solo_company(text) to authenticated;

-- ---------- 3) Admin global ----------
alter table public.users
  add column if not exists is_admin boolean not null default false;

-- Admin principal de la plataforma.
update public.users set is_admin = true where lower(email) = 'didakdp.5@gmail.com';

-- Helper: ¿el usuario autenticado es admin de plataforma? (SECURITY DEFINER
-- para no chocar con RLS). Se usa para endurecer/relajar políticas si hiciera
-- falta; el panel admin real va por el backend con service_role.
create or replace function public.is_platform_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select coalesce((select is_admin from public.users where id = auth.uid()), false)
$$;

grant execute on function public.is_platform_admin() to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ============================================================
-- TaxiCount - Programa de referidos.
--
-- Cada usuario tiene un código (referral_code). Un usuario nuevo puede
-- introducir el código de quien le invitó (set_my_referrer). Cuando la empresa
-- del referido PAGA por primera vez, el backend recompensa al que invitó con un
-- mes gratis (extiende su trial_ends_at +30 días y, si paga por Stripe, empuja
-- el siguiente cobro). Una recompensa por empresa referida (no duplicable).
-- ============================================================

-- 1) Código de referido por usuario + a quién le invitó.
alter table public.users add column if not exists referral_code text;
update public.users
   set referral_code = upper(substr(md5(random()::text || id::text || clock_timestamp()::text), 1, 6))
 where referral_code is null;
create unique index if not exists users_referral_code_uidx on public.users(referral_code);

alter table public.users
  add column if not exists referred_by uuid references public.users(id) on delete set null;

-- Genera referral_code automáticamente en cada alta de usuario.
create or replace function public.set_referral_code()
returns trigger language plpgsql as $$
begin
  if NEW.referral_code is null then
    NEW.referral_code := upper(substr(md5(random()::text || NEW.id::text || clock_timestamp()::text), 1, 6));
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_set_referral_code on public.users;
create trigger trg_set_referral_code before insert on public.users
  for each row execute function public.set_referral_code();

-- 2) Tabla de referidos: una fila por empresa referida.
create table if not exists public.referrals (
  id                 uuid primary key default gen_random_uuid(),
  referrer_user_id   uuid not null references public.users(id)   on delete cascade,
  referred_user_id   uuid not null references public.users(id)   on delete cascade,
  referred_tenant_id uuid not null references public.tenants(id) on delete cascade,
  status             text not null default 'pending' check (status in ('pending', 'rewarded')),
  created_at         timestamptz not null default now(),
  rewarded_at        timestamptz
);
create unique index if not exists referrals_referred_tenant_uidx on public.referrals(referred_tenant_id);
create index if not exists referrals_referrer_idx on public.referrals(referrer_user_id);

grant select, insert, update, delete on public.referrals to authenticated, service_role;
alter table public.referrals enable row level security;

-- El que invita ve sus referidos; el referido ve su propia fila.
drop policy if exists referrals_select on public.referrals;
create policy referrals_select on public.referrals
  for select to authenticated
  using (referrer_user_id = auth.uid() or referred_user_id = auth.uid());

-- 3) RPC: aplicar el código de quien me invitó (una sola vez, no a mí mismo).
create or replace function public.set_my_referrer(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_tenant   uuid;
  v_existing uuid;
  v_referrer uuid;
begin
  if v_uid is null then raise exception 'No autenticado'; end if;
  select tenant_id, referred_by into v_tenant, v_existing from public.users where id = v_uid;
  if v_tenant is null then raise exception 'Crea tu empresa primero'; end if;
  if v_existing is not null then raise exception 'Ya has usado un código de invitación'; end if;

  select id into v_referrer from public.users where upper(referral_code) = upper(btrim(p_code));
  if v_referrer is null then raise exception 'Código no válido'; end if;
  if v_referrer = v_uid then raise exception 'No puedes invitarte a ti mismo'; end if;
  if exists (select 1 from public.referrals where referred_tenant_id = v_tenant) then
    raise exception 'Esta empresa ya tiene un código aplicado';
  end if;

  update public.users set referred_by = v_referrer where id = v_uid;
  insert into public.referrals (referrer_user_id, referred_user_id, referred_tenant_id)
  values (v_referrer, v_uid, v_tenant);
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.set_my_referrer(text) to authenticated;

notify pgrst, 'reload schema';


-- ============================================================
-- TaxiCount - Marca de tutorial visto por usuario.
-- Antes el "tutorial visto" se guardaba en el navegador (se perdía al limpiar
-- caché y reaparecía). Ahora se guarda por usuario en la BD: se muestra una sola
-- vez de verdad, en cualquier dispositivo.
-- ============================================================
alter table public.users
  add column if not exists tutorial_seen boolean not null default false;

notify pgrst, 'reload schema';


-- ============================================================
-- TaxiCount - Activar/desactivar modo autónomo desde Ajustes.
-- Permite que un propietario marque su empresa como "solo" (él es a la vez
-- propietario y chófer) sin tener que crearla así desde el principio.
-- ============================================================
create or replace function public.set_solo_mode(p_solo boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_tenant uuid;
  v_role   text;
begin
  if v_uid is null then raise exception 'No autenticado'; end if;
  select tenant_id, role::text into v_tenant, v_role from public.users where id = v_uid;
  if v_tenant is null then raise exception 'No perteneces a ninguna empresa'; end if;
  if v_role <> 'owner' then raise exception 'Solo el propietario puede cambiar esto'; end if;
  update public.tenants set solo = coalesce(p_solo, false) where id = v_tenant;
  return true;
end;
$$;
grant execute on function public.set_solo_mode(boolean) to authenticated;

notify pgrst, 'reload schema';


-- ============================================================
-- TaxiCount - El autónomo nace ya como conductor con nombre por defecto.
-- Al crear la empresa en modo autónomo, ponemos display_name = 'Yo mismo' para
-- que la vista Chófer le salude con un nombre (editable después por el usuario).
-- ============================================================
create or replace function public.create_solo_company(p_name text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_existing uuid;
  v_tenant   uuid;
begin
  if v_uid is null then raise exception 'No autenticado'; end if;
  select tenant_id into v_existing from public.users where id = v_uid;
  if v_existing is not null then raise exception 'Ya perteneces a una flota'; end if;

  insert into public.tenants (name, join_code, solo)
  values (
    coalesce(nullif(btrim(p_name), ''), 'Mi taxi'),
    upper(substr(md5(random()::text || v_uid::text || clock_timestamp()::text), 1, 6)),
    true
  )
  returning id into v_tenant;

  -- Es propietario y, a la vez, su propio conductor (display_name por defecto).
  update public.users
     set tenant_id = v_tenant,
         role = 'owner',
         active = true,
         display_name = coalesce(nullif(btrim(display_name), ''), 'Yo mismo')
   where id = v_uid;
  return v_tenant;
end;
$$;
grant execute on function public.create_solo_company(text) to authenticated;

-- ============================================================
-- 030 - Retos / metas por conductor (km_100k, money_100k).
-- ============================================================
create table if not exists public.challenge_claims (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  user_id      uuid not null references public.users(id)   on delete cascade,
  challenge    text not null check (challenge in ('km_100k', 'money_100k', 'days_300')),
  level        int     not null default 1,
  baseline     numeric not null default 0,
  target       numeric not null default 0,
  metric_value numeric not null default 0,
  active_days  int     not null default 0,
  status       text    not null default 'pending'
               check (status in ('pending', 'rewarded', 'rejected')),
  created_at   timestamptz not null default now(),
  reviewed_at  timestamptz
);
alter table public.challenge_claims add column if not exists level int not null default 1;
alter table public.challenge_claims add column if not exists baseline numeric not null default 0;
alter table public.challenge_claims add column if not exists target numeric not null default 0;
drop index if exists public.challenge_claims_user_chal_uidx;
create unique index if not exists challenge_claims_user_chal_lvl_uidx
  on public.challenge_claims(user_id, challenge, level);
create index if not exists challenge_claims_tenant_idx on public.challenge_claims(tenant_id);

grant select, insert, update, delete on public.challenge_claims to authenticated, service_role;
alter table public.challenge_claims enable row level security;

drop policy if exists challenge_claims_select on public.challenge_claims;
create policy challenge_claims_select on public.challenge_claims
  for select to authenticated
  using (
    user_id = auth.uid()
    or (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner')
  );

create or replace function public.challenge_stats(p_user uuid)
returns table(km numeric, money numeric, active_days int)
language sql stable security definer
set search_path = public
as $$
  with odo as (
    select vehicle_id, reading_km::numeric as km, taken_at::date as d
      from public.odometer_readings where user_id = p_user
    union all
    select vehicle_id, odometer_km::numeric as km, created_at::date as d
      from public.transactions
     where user_id = p_user and odometer_km is not null and vehicle_id is not null
  ),
  per_vehicle as (
    select coalesce(sum(max_km - min_km), 0) as km_total
      from (select vehicle_id, max(km) as max_km, min(km) as min_km
              from odo group by vehicle_id) t
  ),
  bal as (
    select coalesce(sum(case when type = 'income' then amount else -amount end), 0) as money
      from public.transactions where user_id = p_user
  ),
  days as (
    select count(distinct d) as n from (
      select created_at::date as d from public.transactions where user_id = p_user
      union
      select taken_at::date as d from public.odometer_readings where user_id = p_user
    ) x
  )
  select (select km_total from per_vehicle),
         (select money from bal),
         (select n from days)::int;
$$;
grant execute on function public.challenge_stats(uuid) to service_role;

-- Drop previo: esta definición antigua (sin max_income) quedó superada por la
-- de más abajo (con max_income). Sin el drop, re-ejecutar cloud_setup falla con
-- "cannot change return type of existing function".
drop function if exists public.challenge_stats_tenant(uuid);
create or replace function public.challenge_stats_tenant(p_tenant uuid)
returns table(
  user_id uuid, name text, email text,
  km numeric, money numeric, active_days int, max_jump numeric
)
language sql stable security definer
set search_path = public
as $$
  with odo as (
    select user_id, vehicle_id, reading_km::numeric as km, taken_at::date as d
      from public.odometer_readings where tenant_id = p_tenant
    union all
    select user_id, vehicle_id, odometer_km::numeric as km, created_at::date as d
      from public.transactions
     where tenant_id = p_tenant and odometer_km is not null and vehicle_id is not null
  ),
  km_per_user as (
    -- Punto 7: km del reto = max(lectura) - base, base = registered_km del coche
    -- (km al alta) si está fijado, o la primera lectura si no. Clamp a >= 0.
    select t.user_id,
           coalesce(sum(greatest(0, t.mx - coalesce(v.registered_km, t.mn))), 0) as km
      from (
        select user_id, vehicle_id, max(km) as mx, min(km) as mn
          from odo group by user_id, vehicle_id
      ) t
      left join public.vehicles v on v.id = t.vehicle_id
     group by t.user_id
  ),
  jumps as (
    select user_id, coalesce(max(km - prev), 0) as max_jump from (
      select user_id, km,
             lag(km) over (partition by user_id, vehicle_id order by km) as prev
        from odo
    ) z where prev is not null group by user_id
  ),
  money_per_user as (
    select user_id, coalesce(sum(case when type = 'income' then amount else -amount end), 0) as money
      from public.transactions where tenant_id = p_tenant group by user_id
  ),
  days_per_user as (
    select user_id, count(distinct d) as active_days from (
      select user_id, created_at::date as d from public.transactions where tenant_id = p_tenant
      union
      select user_id, taken_at::date as d from public.odometer_readings where tenant_id = p_tenant
    ) x group by user_id
  )
  select u.id, u.name, u.email,
         coalesce(k.km, 0), coalesce(m.money, 0),
         coalesce(d.active_days, 0)::int, coalesce(j.max_jump, 0)
    from public.users u
    left join km_per_user k    on k.user_id = u.id
    left join money_per_user m on m.user_id = u.id
    left join days_per_user d  on d.user_id = u.id
    left join jumps j          on j.user_id = u.id
   where u.tenant_id = p_tenant and u.active is not false
   order by coalesce(k.km, 0) desc;
$$;
grant execute on function public.challenge_stats_tenant(uuid) to service_role;

-- ============================================================
-- 031 - Ocultar incidencias en el panel de empresa (soft-delete).
-- ============================================================
alter table public.incidents
  add column if not exists hidden_for_tenant boolean not null default false;

drop policy if exists incidents_select on public.incidents;
create policy incidents_select on public.incidents
  for select to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (public.current_role_name() = 'owner' or user_id = auth.uid())
    and hidden_for_tenant = false
  );

-- ============================================================
-- 032 - Días reales de uso de la app (reto de días).
-- ============================================================
create table if not exists public.app_usage_days (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  user_id   uuid not null references public.users(id)   on delete cascade,
  day       date not null,
  primary key (user_id, day)
);
create index if not exists app_usage_days_tenant_idx on public.app_usage_days(tenant_id);

grant select, insert on public.app_usage_days to authenticated, service_role;
alter table public.app_usage_days enable row level security;

drop policy if exists app_usage_insert on public.app_usage_days;
create policy app_usage_insert on public.app_usage_days
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists app_usage_select on public.app_usage_days;
create policy app_usage_select on public.app_usage_days
  for select to authenticated
  using (
    user_id = auth.uid()
    or (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner')
  );

drop function if exists public.challenge_stats_tenant(uuid);
create or replace function public.challenge_stats_tenant(p_tenant uuid)
returns table(
  user_id uuid, name text, email text,
  km numeric, money numeric, active_days int, max_jump numeric, max_income numeric
)
language sql stable security definer
set search_path = public
as $$
  with odo as (
    select user_id, vehicle_id, reading_km::numeric as km, taken_at::date as d
      from public.odometer_readings where tenant_id = p_tenant
    union all
    select user_id, vehicle_id, odometer_km::numeric as km, created_at::date as d
      from public.transactions
     where tenant_id = p_tenant and odometer_km is not null and vehicle_id is not null
  ),
  km_per_user as (
    -- Punto 7: km del reto = max(lectura) - base, base = registered_km del coche
    -- (km al alta) si está fijado, o la primera lectura si no. Clamp a >= 0.
    select t.user_id,
           coalesce(sum(greatest(0, t.mx - coalesce(v.registered_km, t.mn))), 0) as km
      from (
        select user_id, vehicle_id, max(km) as mx, min(km) as mn
          from odo group by user_id, vehicle_id
      ) t
      left join public.vehicles v on v.id = t.vehicle_id
     group by t.user_id
  ),
  jumps as (
    select user_id, coalesce(max(km - prev), 0) as max_jump from (
      select user_id, km,
             lag(km) over (partition by user_id, vehicle_id order by km) as prev
        from odo
    ) z where prev is not null group by user_id
  ),
  money_per_user as (
    select user_id, coalesce(sum(case when type = 'income' then amount else -amount end), 0) as money
      from public.transactions where tenant_id = p_tenant group by user_id
  ),
  income_per_user as (
    select user_id, coalesce(max(amount), 0) as max_income
      from public.transactions where tenant_id = p_tenant and type = 'income' group by user_id
  ),
  days_per_user as (
    select user_id, count(distinct d) as active_days from (
      select user_id, created_at::date as d from public.transactions where tenant_id = p_tenant
      union
      select user_id, taken_at::date as d from public.odometer_readings where tenant_id = p_tenant
      union
      select user_id, day as d from public.app_usage_days where tenant_id = p_tenant
    ) x group by user_id
  )
  select u.id, u.name, u.email,
         coalesce(k.km, 0), coalesce(m.money, 0),
         coalesce(d.active_days, 0)::int, coalesce(j.max_jump, 0), coalesce(i.max_income, 0)
    from public.users u
    left join km_per_user k     on k.user_id = u.id
    left join money_per_user m  on m.user_id = u.id
    left join income_per_user i on i.user_id = u.id
    left join days_per_user d   on d.user_id = u.id
    left join jumps j           on j.user_id = u.id
   where u.tenant_id = p_tenant and u.active is not false
   order by coalesce(k.km, 0) desc;
$$;
grant execute on function public.challenge_stats_tenant(uuid) to service_role;

notify pgrst, 'reload schema';

-- ============================================================
-- 033 - Programa de referidos v2 (por hitos). Reemplaza el simple (026).
-- Idempotente: rename guardado, if not exists, on conflict.
-- ============================================================
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

-- 034 - Realtime para referidos (idempotente).
-- ============================================================
-- TaxiCount - Realtime para referidos.
-- Permite que la pantalla "Invita y Gana" se actualice EN VIVO cuando un
-- referido se valida o se concede un hito (sin tener que refrescar a mano).
-- Añade las tablas a la publicación supabase_realtime (respeta RLS: cada
-- usuario solo recibe cambios de sus propias filas). Idempotente.
-- ============================================================
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'referrals')
  then
    alter publication supabase_realtime add table public.referrals;
  end if;

  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'referral_milestone_rewards')
  then
    alter publication supabase_realtime add table public.referral_milestone_rewards;
  end if;
end $$;


-- ============================================================
-- 035 - Métricas trimestrales de flota (gamificación sostenible).
-- ============================================================
-- Loop #4: cambia la recompensa de retos de "1 mes por conductor" (insostenible)
-- a un modelo TRIMESTRAL por % de flota activa. Solo crea estructura nueva
-- (no toca challenge_claims ni datos existentes). Idempotente.
-- ============================================================
create table if not exists public.fleet_quarterly_metrics (
  id                        uuid primary key default gen_random_uuid(),
  tenant_id                 uuid not null references public.tenants(id) on delete cascade,
  year                      int  not null,
  quarter                   int  not null check (quarter between 1 and 4),
  active_drivers            int  not null default 0,
  drivers_with_achievement  int  not null default 0,
  completion_rate           numeric(5,2) not null default 0,
  reward_days_awarded       int  not null default 0,
  processed_at              timestamptz not null default now(),
  unique (tenant_id, year, quarter)
);
create index if not exists idx_fleet_quarterly_tenant
  on public.fleet_quarterly_metrics(tenant_id, year desc, quarter desc);
grant select on public.fleet_quarterly_metrics to authenticated;
grant select, insert, update, delete on public.fleet_quarterly_metrics to service_role;
alter table public.fleet_quarterly_metrics enable row level security;
drop policy if exists fleet_quarterly_select on public.fleet_quarterly_metrics;
create policy fleet_quarterly_select on public.fleet_quarterly_metrics
  for select to authenticated
  using (
    public.is_platform_admin()
    or (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner')
  );

create table if not exists public.cron_execution_logs (
  id                 uuid primary key default gen_random_uuid(),
  job_name           text not null,
  period_label       text,
  started_at         timestamptz not null default now(),
  finished_at        timestamptz,
  status             text not null default 'running' check (status in ('running','success','error')),
  tenants_processed  int  not null default 0,
  rewards_granted    int  not null default 0,
  details            jsonb,
  error              text
);
create index if not exists idx_cron_logs_job_started
  on public.cron_execution_logs(job_name, started_at desc);
grant select on public.cron_execution_logs to authenticated;
grant select, insert, update, delete on public.cron_execution_logs to service_role;
alter table public.cron_execution_logs enable row level security;
drop policy if exists cron_logs_select on public.cron_execution_logs;
create policy cron_logs_select on public.cron_execution_logs
  for select to authenticated
  using (public.is_platform_admin());


-- ============================================================
-- 036 - Log de auditoría de acciones administrativas (Loop #5).
-- ============================================================
create table if not exists public.admin_actions_log (
  id           uuid primary key default gen_random_uuid(),
  admin_id     uuid references public.users(id) on delete set null,
  action_type  text not null,
  target_type  text,
  target_id    text,
  details      jsonb,
  ip_address   text,
  created_at   timestamptz not null default now()
);
create index if not exists idx_admin_actions_created on public.admin_actions_log(created_at desc);
create index if not exists idx_admin_actions_admin   on public.admin_actions_log(admin_id, created_at desc);
create index if not exists idx_admin_actions_target  on public.admin_actions_log(target_type, target_id);
grant select on public.admin_actions_log to authenticated;
grant select, insert on public.admin_actions_log to service_role;
alter table public.admin_actions_log enable row level security;
drop policy if exists admin_actions_select on public.admin_actions_log;
create policy admin_actions_select on public.admin_actions_log
  for select to authenticated
  using (public.is_platform_admin());


-- ============================================================
-- 037 - Alertas de fraude genéricas (centro de fraude, Loop #5).
-- ============================================================
create table if not exists public.fraud_alerts (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid references public.tenants(id) on delete cascade,
  user_id          uuid references public.users(id)   on delete set null,
  alert_type       text not null,
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
drop policy if exists fraud_alerts_select on public.fraud_alerts;
create policy fraud_alerts_select on public.fraud_alerts
  for select to authenticated
  using (public.is_platform_admin());

notify pgrst, 'reload schema';


-- ============================================================
-- 038 - ITV del taxímetro (fecha de caducidad), aparte de la ITV general.
-- ============================================================
alter table public.vehicles
  add column if not exists taximeter_itv_expiry date;

notify pgrst, 'reload schema';


-- ============================================================
-- 040 - C-01: bloqueo de columnas sensibles en public.users.
-- Evita que un usuario se autoconceda is_admin/owner o cambie de tenant
-- vía PATCH directo a PostgREST. Mismo patrón que public.tenants.
-- Los GRANT de columna NO afectan a las funciones SECURITY DEFINER ni a
-- service_role, así que el onboarding (create_solo_company, join_fleet...)
-- y el backend siguen funcionando.
-- ============================================================
revoke update on public.users from authenticated;
grant update (display_name, username, avatar_url, license_number,
              has_completed_onboarding, tutorial_seen)
  on public.users to authenticated;

notify pgrst, 'reload schema';


-- ============================================================
-- 041 - M-05: forzar cambio de contraseña temporal en el primer login.
-- El backend (service_role) marca must_change_password al crear/resetear un
-- conductor; el usuario la limpia vía RPC tras cambiarla. La columna NO está en
-- el grant de 040, así que no se puede falsear por PATCH directo.
-- ============================================================
alter table public.users
  add column if not exists must_change_password boolean not null default false;

create or replace function public.mark_password_changed()
returns void
language sql
security definer
set search_path = public
as $$
  update public.users set must_change_password = false where id = auth.uid();
$$;

grant execute on function public.mark_password_changed() to authenticated;

notify pgrst, 'reload schema';


-- ============================================================
-- 042 - Reducir la superficie del rol anon (P3-01 + P3-02).
-- P3-02: anon ya no tiene SELECT global (riesgo de tabla futura sin RLS);
--        solo lee system_config (lectura pública intencionada).
-- P3-01: el login con usuario lo resuelve el backend; se revoca la RPC anónima
--        username->email para evitar enumeración de correos.
-- ============================================================
revoke select on all tables in schema public from anon;
grant select on public.system_config to anon;
revoke execute on function public.email_for_username(text) from anon, authenticated;

notify pgrst, 'reload schema';


-- ============================================================
-- 043 - Aceptación obligatoria de los términos legales (RGPD).
-- ============================================================
alter table public.users
  add column if not exists legal_accepted_version int not null default 0;
alter table public.users
  add column if not exists legal_accepted_at timestamptz;

create or replace function public.accept_legal(p_version int)
returns void
language sql
security definer
set search_path = public
as $$
  update public.users
     set legal_accepted_version = greatest(coalesce(legal_accepted_version, 0), p_version),
         legal_accepted_at = now()
   where id = auth.uid();
$$;

grant execute on function public.accept_legal(int) to authenticated;

notify pgrst, 'reload schema';


-- ============================================================
-- 044 - Conservación fiscal 5 años: al borrar conductor -> carreras
-- anonimizadas (user_id null); baja de empresa -> cierre lógico; purga >5 años.
-- ============================================================
alter table public.transactions alter column user_id drop not null;
alter table public.transactions drop constraint if exists transactions_user_id_fkey;
alter table public.transactions
  add constraint transactions_user_id_fkey
  foreign key (user_id) references public.users(id) on delete set null on update cascade;

alter table public.tenants add column if not exists closed_at timestamptz;

create or replace function public.purge_expired_retention()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_count integer;
begin
  delete from public.tenants
   where closed_at is not null
     and closed_at < now() - interval '5 years';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.purge_expired_retention() from public, anon, authenticated;
grant execute on function public.purge_expired_retention() to service_role;

notify pgrst, 'reload schema';
