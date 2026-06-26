-- ============================================================
-- TaxiCount - Marca de tutorial visto por usuario.
-- Antes el "tutorial visto" se guardaba en el navegador (se perdía al limpiar
-- caché y reaparecía). Ahora se guarda por usuario en la BD: se muestra una sola
-- vez de verdad, en cualquier dispositivo.
-- ============================================================
alter table public.users
  add column if not exists tutorial_seen boolean not null default false;
