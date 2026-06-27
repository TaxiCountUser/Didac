-- ============================================================
-- TaxiCount - Días reales de uso de la app (para el reto de días).
--
-- El reto de "300 días usando la app" debe contar DÍAS DE CALENDARIO reales, no
-- logins ni sesiones. Esta tabla guarda como mucho UNA fila por (conductor, día):
-- al abrir la app se registra el día de hoy (idempotente por la PK). Así, aunque
-- entre 10 veces en un día, cuenta 1; y cuenta aunque ese día no registre nada.
-- ============================================================
create table if not exists public.app_usage_days (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  user_id   uuid not null references public.users(id)   on delete cascade,
  day       date not null,
  primary key (user_id, day)
);
create index if not exists app_usage_days_tenant_idx on public.app_usage_days(tenant_id);

grant select, insert on public.app_usage_days to authenticated, service_role;
alter table public.app_usage_days enable row level security;

-- Cada uno registra su propio día; lo ven él y el owner de su empresa.
drop policy if exists app_usage_insert on public.app_usage_days;
create policy app_usage_insert on public.app_usage_days
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists app_usage_select on public.app_usage_days;
create policy app_usage_select on public.app_usage_days
  for select to authenticated
  using (
    user_id = auth.uid()
    or (tenant_id = public.current_tenant_id() and public.current_role_name() = 'owner')
  );

-- Recalcula challenge_stats_tenant incluyendo los días de uso de la app en el
-- conteo de días activos (además de transacciones y lecturas de km).
create or replace function public.challenge_stats_tenant(p_tenant uuid)
returns table(
  user_id uuid, name text, email text,
  km numeric, money numeric, active_days int, max_jump numeric
)
language sql stable security definer
set search_path = public
as $$
  with odo as (
    select user_id, vehicle_id, reading_km::numeric as km, taken_at::date as d
      from public.odometer_readings where tenant_id = p_tenant
    union all
    select user_id, vehicle_id, odometer_km::numeric as km, created_at::date as d
      from public.transactions
     where tenant_id = p_tenant and odometer_km is not null and vehicle_id is not null
  ),
  km_per_user as (
    select user_id, coalesce(sum(mx - mn), 0) as km from (
      select user_id, vehicle_id, max(km) as mx, min(km) as mn
        from odo group by user_id, vehicle_id
    ) t group by user_id
  ),
  jumps as (
    select user_id, coalesce(max(km - prev), 0) as max_jump from (
      select user_id, km,
             lag(km) over (partition by user_id, vehicle_id order by km) as prev
        from odo
    ) z where prev is not null group by user_id
  ),
  money_per_user as (
    select user_id, coalesce(sum(case when type = 'income' then amount else -amount end), 0) as money
      from public.transactions where tenant_id = p_tenant group by user_id
  ),
  days_per_user as (
    select user_id, count(distinct d) as active_days from (
      select user_id, created_at::date as d from public.transactions where tenant_id = p_tenant
      union
      select user_id, taken_at::date as d from public.odometer_readings where tenant_id = p_tenant
      union
      select user_id, day as d from public.app_usage_days where tenant_id = p_tenant
    ) x group by user_id
  )
  select u.id, u.name, u.email,
         coalesce(k.km, 0), coalesce(m.money, 0),
         coalesce(d.active_days, 0)::int, coalesce(j.max_jump, 0)
    from public.users u
    left join km_per_user k    on k.user_id = u.id
    left join money_per_user m on m.user_id = u.id
    left join days_per_user d  on d.user_id = u.id
    left join jumps j          on j.user_id = u.id
   where u.tenant_id = p_tenant and u.active is not false
   order by coalesce(k.km, 0) desc;
$$;
grant execute on function public.challenge_stats_tenant(uuid) to service_role;
