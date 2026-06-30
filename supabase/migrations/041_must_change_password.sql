-- ============================================================
-- 041 - M-05: forzar cambio de contrasena temporal en el primer login.
--
-- Los conductores se crean con una contrasena temporal generada por el
-- sistema (o reseteada por el jefe). Marcamos la cuenta para obligar a
-- cambiarla en el primer acceso. La marca la pone el backend (service_role)
-- al crear/resetear; la quita el propio usuario via RPC tras cambiarla.
-- ============================================================
alter table public.users
  add column if not exists must_change_password boolean not null default false;

-- RPC para que el usuario marque su contrasena como ya cambiada.
-- SECURITY DEFINER: must_change_password NO esta en el grant de columnas de
-- 'authenticated' (ver migracion 040), asi que no se puede tocar por PATCH
-- directo; solo a traves de esta funcion, y solo para la propia fila.
create or replace function public.mark_password_changed()
returns void
language sql
security definer
set search_path = public
as $$
  update public.users set must_change_password = false where id = auth.uid();
$$;

grant execute on function public.mark_password_changed() to authenticated;

notify pgrst, 'reload schema';
