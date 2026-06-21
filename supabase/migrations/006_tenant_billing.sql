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
