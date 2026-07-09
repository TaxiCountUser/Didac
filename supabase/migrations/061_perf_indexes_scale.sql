-- ============================================================
-- 061 — Índices de rendimiento para el salto de escala (Mes 1)
-- Solo lo que FALTA: los índices críticos de transactions ya
-- existen desde 005 (tenant+created, user+created, created).
-- ============================================================

-- Retos por días activos: el cron y challenge_stats consultan
-- app_usage_days por tenant + rango de días. La PK es (user_id, day)
-- y el índice actual solo cubre tenant_id (sin day).
create index if not exists idx_app_usage_days_tenant_day
  on public.app_usage_days (tenant_id, day);

-- Cierre de jornada / resumen por periodo (periodReport): filtra por
-- user_id + rango de taken_at. Hoy solo hay (vehicle_id, taken_at) y
-- (tenant_id); sin este índice, el flujo más frecuente del conductor
-- escanea todas sus lecturas.
create index if not exists idx_odometer_user_taken
  on public.odometer_readings (user_id, taken_at);
