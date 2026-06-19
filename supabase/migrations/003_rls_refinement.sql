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
