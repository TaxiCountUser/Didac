-- ============================================================
-- TaxiCount - "Sacar de la flota" (despedir/desactivar conductor).
-- Un conductor con active=false queda FUERA de la flota: no puede leer ni
-- escribir ningún dato del tenant (carreras, incidencias, ubicación...). En la
-- app solo ve la pantalla "no tienes ninguna flota activa".
--
-- Mecanismo: current_tenant_id() devuelve NULL para un usuario inactivo, así
-- todas las políticas RLS que comparan con current_tenant_id() cierran en
-- falso. La fila propia sigue siendo legible (users_select: id = auth.uid())
-- para que la app pueda detectar el estado y mostrar la pantalla de bloqueo.
-- ============================================================
alter table public.users add column if not exists active boolean not null default true;

create or replace function public.current_tenant_id()
returns uuid
language sql stable security definer
set search_path = public
as $$
  select tenant_id from public.users where id = auth.uid() and active is true
$$;
