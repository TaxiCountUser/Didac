-- ============================================================================
-- 069 — Cupón activo (config) + marca de canje por tenant
--
-- Modelo nuevo de cupones: hay UN cupón activo (p. ej. TAXICOUNT50 = 50% anual,
-- 1 uso por paquete de conductores). La app muestra un aviso con el código y un
-- botón de copiar cada vez que el owner entra a Suscripción, HASTA que pague
-- usándolo; a partir de ahí no reaparece, salvo que se cambie el cupón activo.
--
--   system_config.active_coupon = {"code":"TAXICOUNT50","pct":50}
--   tenants.coupon_redeemed_code = código del cupón que ese tenant ya canjeó
--     (el aviso se muestra si active_coupon.code != coupon_redeemed_code)
-- Idempotente.
-- ============================================================================
alter table public.tenants
  add column if not exists coupon_redeemed_code text;

insert into public.system_config (key, value)
values ('active_coupon', '{"code":"TAXICOUNT50","pct":50}')
on conflict (key) do nothing;
