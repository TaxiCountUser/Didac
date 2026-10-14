-- ============================================================
-- TaxiCount - 092: versión de la app de cada móvil apuntado a las push.
--
-- Para poder saber, cuando a alguien no le llegan los avisos, qué build tiene
-- instalado ese móvil (p. ej. "1.0.112"). La app la manda al apuntarse
-- (POST /api/v1/device-token). NULL = móviles con builds anteriores.
-- ============================================================

alter table public.device_tokens add column if not exists app_version text;

notify pgrst, 'reload schema';
