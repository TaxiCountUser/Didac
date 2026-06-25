-- TaxiCount - Avatar del usuario (foto en base64 o null = icono).
alter table public.users add column if not exists avatar_url text;
