-- ============================================================================
-- 085_account_deletion.sql
-- Borrado de cuenta a petición del usuario (RGPD art. 17) COMPATIBLE con la
-- retención fiscal obligatoria (5 años, ley española). Modelo: BORRADO LÓGICO.
--
-- El usuario solicita el borrado -> se marca `deleted_at`, la cuenta queda
-- INUTILIZABLE (no puede iniciar sesión) y "sale como borrada", pero los datos
-- (perfil mínimo + carreras, necesarios para contabilidad) se CONSERVAN. El
-- borrado FÍSICO (purga de perfil + cuenta Auth) lo decide la ADMINISTRACIÓN,
-- tras el periodo de retención. Requisito de Google Play (borrado de cuenta) y
-- válido ante la AEPD (se retiene solo lo que obliga la ley, y se informa).
--
-- Aditivo, idempotente y de bajo riesgo. No borra ni cambia datos existentes.
-- ============================================================================

alter table public.users
  add column if not exists deleted_at timestamptz;

comment on column public.users.deleted_at is
  'Fecha de solicitud de borrado por el propio usuario (RGPD). La cuenta queda '
  'inutilizable (no puede iniciar sesión) pero los datos se conservan por '
  'retención fiscal (5 años); la purga física la decide la administración.';

-- Índice parcial: la administración lista rápido las cuentas pendientes de purga.
create index if not exists users_deleted_at_idx
  on public.users (deleted_at)
  where deleted_at is not null;
