-- ============================================================================
-- BORRAR los robots de Google (informe previo al lanzamiento de Play) SIN uso.
-- Ejecutar en Supabase -> SQL Editor (proyecto TaxiCount) -> pegar -> Run.
--
-- Criterios ESTRICTOS (solo borra si se cumplen TODOS):
--   * entró con Google;
--   * correo con la forma nombreapellido.12345@gmail.com;
--   * no es admin;
--   * está solo en su empresa (o no tiene empresa) y esa empresa no tiene
--     suscripción, coches, carreras, agenda ni jornadas;
--   * no tiene lecturas de km ni carreras propias.
-- A 2026-10-15 eran 12: kathrynjordan.53427, kerrygoodman.30027,
-- sophieholloway.96741, cecilwebster.41406, carychristensen.65662,
-- danielfitzgerald.06113, clairetorres.25353, kirkwebster.18430,
-- joannaerickson.27733, neliabowens.96486, sethgutierrez.63617,
-- guillermogeorge.68072.
-- Es DEFINITIVO. Hay copia de seguridad de la BD de hoy (backup-db.yml).
-- Al final muestra cuántas cuentas ha borrado.
-- ============================================================================
begin;

create temp table robots on commit drop as
select u.id as user_id, u.tenant_id
from auth.users au
join public.users u on u.id = au.id
left join public.tenants t on t.id = u.tenant_id
where au.raw_app_meta_data->>'provider' = 'google'
  and u.email ~ '^[a-z]+\.[0-9]{5}@gmail\.com$'
  and not coalesce(u.is_admin, false)
  and (t.id is null or (
        (select count(*) from public.users x where x.tenant_id = t.id) = 1
    and t.stripe_subscription_id is null
    and not exists (select 1 from public.vehicles v where v.tenant_id = t.id)
    and not exists (select 1 from public.transactions x where x.tenant_id = t.id)
    and not exists (select 1 from public.agenda_events x where x.tenant_id = t.id)
    and not exists (select 1 from public.work_shifts x where x.tenant_id = t.id)))
  and not exists (select 1 from public.odometer_readings o where o.user_id = u.id)
  and not exists (select 1 from public.transactions x where x.user_id = u.id);

delete from public.users  where id in (select user_id from robots);
delete from auth.users    where id in (select user_id from robots);
delete from public.tenants where id in (select tenant_id from robots where tenant_id is not null);

select count(*) as cuentas_borradas from robots;

commit;
