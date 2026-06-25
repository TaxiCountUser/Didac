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
