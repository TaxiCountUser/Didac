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
