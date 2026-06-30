-- ============================================================
-- 040 - C-01: bloqueo de columnas sensibles en public.users
--
-- PROBLEMA: el rol `authenticated` tenía UPDATE sobre TODAS las columnas de
-- public.users, y la politica RLS `users_update_self` solo comprueba la fila
-- (id = auth.uid()), no las columnas. Cualquier usuario podia hacer:
--   PATCH /rest/v1/users?id=eq.<su_uid>  {"is_admin": true}
-- y autoconcederse admin / owner / cambiar de tenant.
--
-- SOLUCION (mismo patron que ya se aplica a public.tenants):
--   1) Revocar el UPDATE total al rol authenticated.
--   2) Conceder UPDATE solo en las columnas que el propio usuario edita.
--
-- IMPORTANTE: los GRANT de columna NO afectan a las funciones SECURITY DEFINER
-- (create_solo_company, join_fleet_with_code, set_solo_mode...), que se ejecutan
-- con los privilegios del owner de la funcion y SI pueden seguir cambiando
-- role/tenant_id. Tampoco afectan a service_role (backend Fastify), que conserva
-- UPDATE total para altas, cambios de contrasena, activar/desactivar, etc.
-- Por eso NO usamos un trigger de "congelar columnas": romperia el onboarding.
-- ============================================================

revoke update on public.users from authenticated;
grant update (display_name, username, avatar_url, license_number,
              has_completed_onboarding, tutorial_seen)
  on public.users to authenticated;

notify pgrst, 'reload schema';
