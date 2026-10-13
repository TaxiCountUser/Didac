-- ============================================================
-- TaxiCount - Recordatorios push de la agenda (agenda_reminders.js).
--
-- El backend avisa 1 día antes (o la víspera a las 21:00 si caería de madrugada)
-- y 1 hora antes de cada servicio pendiente: al conductor asignado o, si no hay,
-- al jefe/autónomo. Esta tabla registra lo enviado para avisar UNA sola vez.
-- `ref` = scheduled_at del servicio: si se cambia de hora, vuelve a avisar.
-- Solo el backend (service_role) accede.
-- ============================================================

create table if not exists public.agenda_reminders_sent (
  event_id  uuid not null references public.agenda_events(id) on delete cascade,
  kind      text not null,                      -- day | hour
  ref       text not null,
  sent_at   timestamptz not null default now(),
  primary key (event_id, kind, ref)
);

grant select, insert, update, delete on public.agenda_reminders_sent to service_role;
alter table public.agenda_reminders_sent enable row level security;
-- Sin políticas para authenticated: solo el backend con service_role accede.
