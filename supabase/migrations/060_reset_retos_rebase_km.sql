-- ============================================================================
-- 060_reset_retos_rebase_km.sql   (mantenimiento, 2026-07-04)
--
-- RESET de los retos: usuarios antiguos tenían el reto de km "superado" con
-- kilómetros mal contados (antes del arreglo de initial_odometer, Loop #6).
--
-- 1) RE-BASE: el punto de partida (initial_odometer) de CADA vehículo pasa a
--    ser su lectura más alta conocida (lecturas de cuentakilómetros y
--    transacciones). Así el progreso de km de todos los retos vuelve a 0 desde
--    hoy y NO se re-completan solos con los datos inflados.
-- 2) BORRADO de todos los retos registrados (challenge_claims): niveles y
--    logros se recalculan desde cero a partir de ahora.
--
-- NOTA: el reto de DÍAS podría re-registrarse solo si un conductor de verdad
-- acumula los días de actividad requeridos — eso son datos reales, es correcto.
-- En una base de datos nueva este script no hace nada (idempotente).
-- ============================================================================

-- Foto previa (opcional, solo informativa): cuántos retos hay y si alguno ya
-- canjeó crédito en Stripe (si amb_credit > 0, ese crédito ya está abonado y
-- borrarlo aquí NO lo revierte en Stripe).
-- select status, count(*) as total, count(reward_redeemed_at) as amb_credit
--   from public.challenge_claims group by status;

-- 1) Re-base de los contadores de todos los vehículos.
update public.vehicles v
set initial_odometer = greatest(
  coalesce(v.initial_odometer, 0),
  coalesce(v.registered_km, 0),
  coalesce((select max(r.reading_km) from public.odometer_readings r
             where r.vehicle_id = v.id), 0),
  coalesce((select max(t.odometer_km)::int from public.transactions t
             where t.vehicle_id = v.id and t.odometer_km is not null), 0)
);

-- 2) Borrar todos los retos registrados.
delete from public.challenge_claims;
