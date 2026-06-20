-- ============================================================
-- TaxiCount - Fase 3 (DashboardSyncLoop)
-- Índices para las consultas frecuentes del dashboard:
--   - listado/paginación por tenant ordenado por fecha
--   - historial del driver ordenado por fecha
-- (idx_transactions_tenant e idx_transactions_user ya existen en 001;
--  aquí añadimos los que faltan para ORDER BY created_at eficiente.)
-- ============================================================

-- Orden descendente por fecha dentro de un tenant (dashboard del Owner).
create index if not exists idx_transactions_tenant_created
  on public.transactions (tenant_id, created_at desc);

-- Orden descendente por fecha de un usuario (historial del Driver).
create index if not exists idx_transactions_user_created
  on public.transactions (user_id, created_at desc);

-- Índice plano por fecha (filtros de periodo globales).
create index if not exists idx_transactions_created
  on public.transactions (created_at desc);

-- ---------- Realtime: esquemas del servidor (opcional) ----------
-- El servicio supabase/realtime migra en _realtime (repo principal) y en
-- realtime (extensión CDC por tenant); ambos deben existir de antemano.
create schema if not exists _realtime;
create schema if not exists realtime;

-- ---------- Realtime: publicar la tabla transactions (Tarea 4) ----------
do $$ begin
  alter publication supabase_realtime add table public.transactions;
exception
  when duplicate_object then null;  -- ya está en la publicación
  when undefined_object then null;  -- la publicación no existe en este stack
end $$;

-- ---------- transactions: política DELETE (Tarea 6) ----------
-- Owner: cualquiera de su tenant. Driver: solo las suyas.
drop policy if exists transactions_delete on public.transactions;
create policy transactions_delete on public.transactions
  for delete to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (public.current_role_name() = 'owner' or user_id = auth.uid())
  );
