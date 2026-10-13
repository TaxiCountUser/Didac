-- ============================================================
-- TaxiCount - Correos de bienvenida y fin de prueba (Resend).
--
-- En la app de Google Play no se puede vender ni decir dónde pagar (política de
-- Pagos de Play), así que el aviso de "tu prueba termina, suscríbete en la web"
-- va por CORREO. Un cron diario (trial-emails.yml -> /api/v1/admin/cron/trial-emails)
-- envía al jefe/autónomo:
--   welcome       : bienvenida a quien se registró con Google (no recibe el correo
--                   de verificación de Supabase).
--   trial_ending  : ~3 días antes de que acabe la prueba.
--   trial_ended   : el día que acaba (o justo después).
-- Esta tabla registra lo enviado para mandar cada aviso UNA sola vez. `ref` = fecha
-- de fin de prueba (si un premio alarga la prueba, el aviso vuelve a tocar con la
-- fecha nueva); '-' para la bienvenida.
-- Solo el backend (service_role) accede.
-- ============================================================

create table if not exists public.trial_emails_sent (
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  kind       text not null,                     -- welcome | trial_ending | trial_ended
  ref        text not null default '-',
  email      text,
  sent_at    timestamptz not null default now(),
  primary key (tenant_id, kind, ref)
);

grant select, insert, update, delete on public.trial_emails_sent to service_role;
alter table public.trial_emails_sent enable row level security;
-- Sin políticas para authenticated: solo el backend con service_role accede.
