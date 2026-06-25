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
