-- ============================================================
-- TaxiCount - Inicio de sesión con nombre de usuario (además del correo).
-- Supabase autentica por correo; aquí guardamos un username único y, al entrar,
-- la app traduce username -> email vía email_for_username() y luego hace login.
-- ============================================================
alter table public.users add column if not exists username text;
create unique index if not exists users_username_lower_uidx
  on public.users (lower(username)) where username is not null;

-- Devuelve el correo asociado a un username (para poder iniciar sesión con él).
-- Callable por anon (aún sin sesión). Solo expone el email en coincidencia exacta.
create or replace function public.email_for_username(p_username text)
returns text
language sql
security definer
set search_path = public
stable
as $$
  select email from public.users
   where lower(username) = lower(btrim(p_username))
   limit 1;
$$;
grant execute on function public.email_for_username(text) to anon, authenticated;
