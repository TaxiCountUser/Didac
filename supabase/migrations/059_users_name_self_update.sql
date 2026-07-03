-- ============================================================================
-- 059_users_name_self_update.sql
--
-- El conductor cambia su nombre visible con el lápiz de Ajustes, pero desde la
-- migración 040 (C-01) solo podía actualizar display_name (que el jefe NO ve):
-- el jefe seguía viendo el `name` antiguo en dashboard, informes, incidencias…
--
-- Se añade `name` al GRANT de columnas auto-editables. No es sensible a
-- privilegios (is_admin/role/tenant_id siguen bloqueadas) y RLS
-- (users_update_self) sigue acotando al propio usuario. La app pasa a
-- actualizar name + display_name a la vez (un solo nombre, el último gana).
-- ============================================================================
grant update (name) on public.users to authenticated;

notify pgrst, 'reload schema';
