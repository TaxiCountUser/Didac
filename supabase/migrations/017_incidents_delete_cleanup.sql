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
