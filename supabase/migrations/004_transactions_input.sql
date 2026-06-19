-- ============================================================
-- TaxiCount - Fase 2
-- Habilita la entrada de transacciones (manual + voz) y el
-- contador diario de transcripciones por usuario.
-- ============================================================

-- ---------- transactions: el driver/owner inserta las suyas ----------
drop policy if exists transactions_insert on public.transactions;
create policy transactions_insert on public.transactions
  for insert to authenticated
  with check (
    tenant_id = public.current_tenant_id()
    and user_id = auth.uid()
  );

drop policy if exists transactions_update_own on public.transactions;
create policy transactions_update_own on public.transactions
  for update to authenticated
  using (
    tenant_id = public.current_tenant_id()
    and (public.current_role_name() = 'owner' or user_id = auth.uid())
  )
  with check (tenant_id = public.current_tenant_id());

-- ---------- contador diario de transcripciones (Tarea 7) ----------
alter table public.users
  add column if not exists daily_transcription_count integer not null default 0;
alter table public.users
  add column if not exists transcription_count_date date;
