-- ============================================================
-- TaxiCount - 091: hora de cada carrera "tal como se apuntó".
--
-- created_at guarda el MOMENTO en hora universal (UTC) y no dice en qué país se
-- estaba. Al enseñarla, la app la pasaba a la hora del móvil ACTUAL: una carrera
-- apuntada a las 08:15 en México salía a las 16:15 si luego se miraba desde
-- España (en la app y en el Excel/PDF).
--
-- utc_offset_min = diferencia con UTC, en minutos, que tenía el móvil al apuntar
-- la carrera (España verano +120, invierno +60, Canarias +60/0, México -360…).
-- La app, la web y los informes enseñan cada carrera con SU diferencia, así sale
-- siempre a la hora a la que se apuntó, se mire desde donde se mire.
-- NULL = carreras antiguas (antes de esta migración): se enseñan como hasta ahora
-- (hora del móvil / de España en los informes).
--
-- Sin cambios de RLS: la columna queda cubierta por los grants de la tabla.
-- ============================================================

alter table public.transactions
  add column if not exists utc_offset_min smallint
  check (utc_offset_min is null or utc_offset_min between -840 and 840);

comment on column public.transactions.utc_offset_min is
  'Diferencia con UTC (minutos) del móvil al apuntar la carrera; NULL = antigua.';

notify pgrst, 'reload schema';
