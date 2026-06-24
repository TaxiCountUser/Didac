-- ============================================================
-- TaxiCount - Carreras: metadatos extra para los ingresos.
--
-- Una "carrera" es una transacción de tipo income con datos
-- adicionales que el conductor apunta para llevar un registro
-- detallado (útil p. ej. ante consultas/investigaciones) y para
-- que el propietario controle los km diarios del coche.
--
--   origin        origen del viaje (texto libre, opcional)
--   destination   destino del viaje (texto libre, opcional)
--   odometer_km   km del coche en ese momento (opcional)
--   client_name   empresa/cliente; vacío/NULL => cliente particular
--
-- La "hora" del viaje es created_at (ya existente). Los gastos
-- (type = expense) no usan estos campos.
-- ============================================================

alter table public.transactions
  add column if not exists origin       text,
  add column if not exists destination  text,
  add column if not exists odometer_km  integer,
  add column if not exists client_name  text;

-- Búsqueda/filtrado por empresa (case-insensitive) en informes.
create index if not exists idx_transactions_client_name
  on public.transactions (lower(client_name));

-- El odómetro, si se informa, no puede ser negativo.
alter table public.transactions
  drop constraint if exists transactions_odometer_km_nonneg;
alter table public.transactions
  add constraint transactions_odometer_km_nonneg
  check (odometer_km is null or odometer_km >= 0);
