-- 081_error_reports_owner_rls.sql
-- Limpieza (2026-07-25): quita el acceso de OWNER a error_reports. Era el residuo
-- del "copia al jefe" ya eliminado del backend: NINGÚN screen no-admin lee
-- error_reports, así que la política de owner no la usa nadie. El AUTOR sigue
-- pudiendo ver los suyos; el ADMIN lee vía service_role (no depende de esta RLS).
-- Idempotente (drop if exists + create, como la 047).

drop policy if exists error_reports_select on public.error_reports;
create policy error_reports_select on public.error_reports
  for select to authenticated
  using (user_id = auth.uid());

notify pgrst, 'reload schema';
