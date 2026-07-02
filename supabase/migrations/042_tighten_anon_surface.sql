-- ============================================================
-- 042 - Reducir la superficie del rol anon (P3-01 + P3-02)
--
-- P3-02: el rol anon tenía SELECT sobre TODAS las tablas (grant global). Aunque
--   la RLS lo filtraba, una tabla futura SIN RLS quedaría expuesta a internet.
--   Quitamos el SELECT global a anon y dejamos solo lo imprescindible
--   (system_config, que tiene política de lectura pública intencionada).
--
-- P3-01: el email se resolvía por una RPC anónima (username -> email), lo que
--   permitía enumerar correos. Ahora el login con usuario lo hace el backend
--   (/api/v1/auth/login-username) y nunca expone el email. Revocamos el execute.
-- ============================================================

-- P3-02
revoke select on all tables in schema public from anon;
-- Lectura pública intencionada (config de referidos, sin secretos).
grant select on public.system_config to anon;

-- P3-01. Importante: las funciones conceden EXECUTE a PUBLIC por defecto y anon
-- lo hereda; hay que revocar también de PUBLIC para que la restricción surta
-- efecto (revocar solo de anon deja el permiso vivo vía PUBLIC).
revoke execute on function public.email_for_username(text) from public, anon, authenticated;

notify pgrst, 'reload schema';
