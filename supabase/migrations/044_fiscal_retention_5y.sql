-- ============================================================
-- 044 - Conservación fiscal 5 años (RGPD + obligación mercantil).
--
-- Antes: borrar un conductor o una empresa borraba EN CASCADA sus carreras
-- (transactions), perdiéndose datos que deben conservarse. Ahora:
--
--  - Al borrar un CONDUCTOR: sus carreras se conservan ANONIMIZADAS
--    (transactions.user_id -> NULL) en vez de borrarse.
--  - Al borrar una EMPRESA: se hace CIERRE LÓGICO (tenants.closed_at) y se
--    conservan las carreras; el backend anonimiza y elimina el acceso.
--  - Una purga elimina las empresas cerradas hace más de 5 años (cascada a sus
--    carreras): fin del periodo de conservación.
-- ============================================================

-- 1) transactions.user_id: anulable + ON DELETE SET NULL (conserva la carrera).
alter table public.transactions alter column user_id drop not null;
alter table public.transactions drop constraint if exists transactions_user_id_fkey;
alter table public.transactions
  add constraint transactions_user_id_fkey
  foreign key (user_id) references public.users(id) on delete set null on update cascade;

-- 2) Cierre lógico de empresa (baja con retención).
alter table public.tenants add column if not exists closed_at timestamptz;

-- 3) Purga tras 5 años: elimina empresas cerradas hace >5 años (cascada a sus
--    carreras). Solo la ejecuta el backend (service_role).
create or replace function public.purge_expired_retention()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_count integer;
begin
  delete from public.tenants
   where closed_at is not null
     and closed_at < now() - interval '5 years';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.purge_expired_retention() from public, anon, authenticated;
grant execute on function public.purge_expired_retention() to service_role;

notify pgrst, 'reload schema';
