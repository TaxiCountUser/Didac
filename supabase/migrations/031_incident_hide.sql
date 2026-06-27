-- ============================================================
-- TaxiCount - Ocultar incidencias en el panel de la empresa (soft-delete).
--
-- El jefe puede "borrar" incidencias de su panel (notas de conductor o tickets),
-- pero NO se eliminan de verdad: se marcan hidden_for_tenant = true. El tenant
-- (jefe y conductores) deja de verlas; el ADMIN de plataforma las sigue viendo
-- (va por service_role, que ignora RLS) por si hay una denuncia o problema legal
-- a futuro sobre alguna incidencia.
-- ============================================================
alter table public.incidents
  add column if not exists hidden_for_tenant boolean not null default false;

-- La empresa solo ve las NO ocultas. (El admin no pasa por aquí: usa service_role.)
drop policy if exists incidents_select on public.incidents;
create policy incidents_select on public.incidents
  for select to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (public.current_role_name() = 'owner' or user_id = auth.uid())
    and hidden_for_tenant = false
  );
