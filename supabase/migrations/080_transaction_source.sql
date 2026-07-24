-- 080_transaction_source.sql
-- Origen de ENTRADA de cada transacción: 'voice' (dictado por voz) | 'manual'
-- (escrito a mano). NULL = desconocido (filas creadas antes de esta migración).
-- Sirve para la métrica de ADOPCIÓN DE VOZ del panel admin (solo RECUENTOS
-- agregados de plataforma; nunca importes). Idempotente.
--
-- Nota RLS/grants: NO hace falta grant nuevo. transactions tiene grant a nivel de
-- TABLA, que cubre automáticamente las columnas futuras; el cliente ya inserta
-- bajo su política RLS (tenant/usuario), que esta columna no altera.

alter table public.transactions
  add column if not exists source text;

-- Integridad: solo 'voice' | 'manual' (NULL permitido = desconocido).
do $$ begin
  if not exists (
    select 1 from pg_constraint where conname = 'transactions_source_chk'
  ) then
    alter table public.transactions
      add constraint transactions_source_chk
      check (source is null or source in ('voice', 'manual'));
  end if;
end $$;

-- Índice para contar por origen del día sin escanear toda la tabla.
create index if not exists idx_transactions_source_created
  on public.transactions (created_at, source)
  where source is not null;
