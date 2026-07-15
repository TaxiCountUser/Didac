-- ============================================================
-- TaxiCount - Avisos de mantenimiento de vehículos (recordatorios al jefe).
--
-- Un cron diario revisa las fechas de mantenimiento de cada vehículo (ITV, ITV
-- del taxímetro, seguro, tarjeta de transporte) y la revisión por km, y envía
-- push al/los owner(s) del tenant al cruzar cada hito (30/15/7/1 días, el día,
-- caducado; y ~1000/~200/0 km para la revisión). Cada aviso se envía UNA sola
-- vez: esta tabla guarda los ya enviados (throttle). El "ref" identifica el
-- ciclo (la fecha objetivo o el km objetivo): si el jefe cambia la fecha/km, el
-- ref cambia y se reinician los avisos para el nuevo valor.
-- ============================================================

create table if not exists public.maintenance_reminders_sent (
  id          uuid primary key default gen_random_uuid(),
  vehicle_id  uuid not null references public.vehicles(id) on delete cascade,
  kind        text not null,   -- itv | taximeter_itv | insurance | transport_card | revision_km
  ref         text not null,   -- fecha ISO objetivo o km objetivo (identifica el ciclo)
  milestone   text not null,   -- 30 | 15 | 7 | 1 | 0 | expired | km1000 | km200 | km0
  sent_at     timestamptz not null default now(),
  unique (vehicle_id, kind, ref, milestone)
);

create index if not exists idx_maint_reminders_vehicle
  on public.maintenance_reminders_sent(vehicle_id);

-- Solo el backend (service_role) la usa; authenticated no accede.
grant select, insert on public.maintenance_reminders_sent to service_role;
alter table public.maintenance_reminders_sent enable row level security;
