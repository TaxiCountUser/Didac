-- ============================================================
-- 043 - Aceptación obligatoria de los términos legales (RGPD).
--
-- Cada usuario debe aceptar la versión vigente de los términos/política. Se
-- guarda la versión aceptada y la fecha. La app muestra la pantalla legal
-- mientras legal_accepted_version < kLegalVersion (al registrarse y, para
-- cuentas antiguas, al abrir la app). Al subir la versión, todos re-aceptan.
--
-- La columna se escribe SOLO vía RPC accept_legal (SECURITY DEFINER); no está
-- en el grant de columnas de 'authenticated' (migración 040), así que no se
-- puede falsear por PATCH directo.
-- ============================================================
alter table public.users
  add column if not exists legal_accepted_version int not null default 0;
alter table public.users
  add column if not exists legal_accepted_at timestamptz;

create or replace function public.accept_legal(p_version int)
returns void
language sql
security definer
set search_path = public
as $$
  update public.users
     set legal_accepted_version = greatest(coalesce(legal_accepted_version, 0), p_version),
         legal_accepted_at = now()
   where id = auth.uid();
$$;

grant execute on function public.accept_legal(int) to authenticated;

notify pgrst, 'reload schema';
