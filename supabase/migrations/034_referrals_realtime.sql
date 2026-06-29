-- ============================================================
-- TaxiCount - Realtime para referidos.
-- Permite que la pantalla "Invita y Gana" se actualice EN VIVO cuando un
-- referido se valida o se concede un hito (sin tener que refrescar a mano).
-- Añade las tablas a la publicación supabase_realtime (respeta RLS: cada
-- usuario solo recibe cambios de sus propias filas). Idempotente.
-- ============================================================
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'referrals')
  then
    alter publication supabase_realtime add table public.referrals;
  end if;

  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'referral_milestone_rewards')
  then
    alter publication supabase_realtime add table public.referral_milestone_rewards;
  end if;
end $$;
