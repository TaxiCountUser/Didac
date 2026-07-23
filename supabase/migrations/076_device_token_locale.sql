-- 076_device_token_locale.sql
-- Idioma del dispositivo, para enviar las notificaciones push en el idioma que el
-- usuario tiene configurado en la app (antes salían siempre en castellano, texto
-- hardcodeado en el backend). La app lo sincroniza al registrar el token; el
-- backend agrupa por locale y traduce (ver push_i18n.js). Aditiva, no destructiva.

alter table public.device_tokens
  add column if not exists locale text;
