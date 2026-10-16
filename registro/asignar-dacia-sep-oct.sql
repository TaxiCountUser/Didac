-- ============================================================
-- TaxiCount · Poner el DACIA a las carreras de Didac que se quedaron SIN COCHE
-- (septiembre y octubre de 2026, empresa «Taxi Oliveras»).
--
-- Cómo usarlo (Supabase → SQL Editor, proyecto TaxiCount):
--   1) Ejecuta SOLO el PASO 1 y mira el resultado.
--   2) Si sale lo que esperas (1 conductor, 1 coche y el nº de registros), ejecuta el PASO 2.
-- Solo toca registros SIN coche (vehicle_id vacío). No borra nada.
-- ============================================================

-- ---------- PASO 1: COMPROBAR (no cambia nada) ----------
with t as (select id, name from tenants where name ilike '%taxi oliveras%'),
     u as (select id, name, email from users where tenant_id in (select id from t) and name ilike 'didac%'),
     v as (select id, license_plate, model from vehicles where tenant_id in (select id from t)
             and (model ilike '%dacia%' or license_plate ilike '%dacia%'))
select
  (select count(*) from t) as empresas,              -- debe ser 1
  (select string_agg(name || ' <' || coalesce(email, '') || '>', ' | ') from u) as conductor,   -- debe ser solo 1
  (select string_agg(license_plate || ' ' || coalesce(model, ''), ' | ') from v) as coche,       -- debe ser solo 1 (el Dacia)
  (select count(*) from transactions x
     where x.user_id in (select id from u) and x.vehicle_id is null
       and x.created_at >= '2026-08-31 22:00+00' and x.created_at < '2026-10-31 23:00+00'   -- 1/9 a 31/10 hora de España
       and (x.type = 'income'
            or x.category in ('gasolina', 'gasoil', 'carga_electrica', 'taller', 'peaje', 'parking', 'lavado', 'seguro'))
  ) as registros_a_corregir;

-- ---------- PASO 2: CORREGIR (ejecútalo solo si el paso 1 está bien) ----------
-- Pone el Dacia a las CARRERAS y a los GASTOS DEL COCHE (gasoil, taller, peaje,
-- parking, lavado, seguro…) sin coche. Los gastos que no son del coche
-- (autónomos, seguridad social, compras, otros) se quedan sin coche, como deben.
-- Si hay más de un conductor «Didac» o más de un Dacia, NO cambia nada.
with t as (select id from tenants where name ilike '%taxi oliveras%'),
     u as (select id from users where tenant_id in (select id from t) and name ilike 'didac%'),
     v as (select id from vehicles where tenant_id in (select id from t)
             and (model ilike '%dacia%' or license_plate ilike '%dacia%'))
update transactions x
   set vehicle_id = (select id from v)
 where (select count(*) from t) = 1
   and (select count(*) from u) = 1
   and (select count(*) from v) = 1
   and x.user_id = (select id from u)
   and x.vehicle_id is null
   and x.created_at >= '2026-08-31 22:00+00' and x.created_at < '2026-10-31 23:00+00'
   and (x.type = 'income'
        or x.category in ('gasolina', 'gasoil', 'carga_electrica', 'taller', 'peaje', 'parking', 'lavado', 'seguro'))
returning x.id, x.created_at, x.type, x.amount;
