-- ============================================================
-- TaxiCount - Datos de prueba (seed)
-- Idempotente (ON CONFLICT DO NOTHING).
--
-- NOTA sobre autenticación:
--   Las filas de public.users son perfiles de aplicación. Los
--   usuarios de AUTENTICACIÓN (auth.users) los provisiona el
--   smoke-test mediante la Admin API y luego re-mapea el id del
--   perfil al id real de auth (los FK usan ON UPDATE CASCADE).
-- ============================================================

-- Tenants ----------------------------------------------------
insert into public.tenants (id, name) values
  ('11111111-1111-1111-1111-111111111111', 'Autónomo de prueba'),
  ('22222222-2222-2222-2222-222222222222', 'Otro tenant (aislamiento)')
on conflict (id) do nothing;

-- Perfiles de usuario (tenant A) -----------------------------
insert into public.users (id, tenant_id, email, password_hash, role) values
  ('a0000000-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111',
   'owner@test.com',  'managed-by-gotrue', 'owner'),
  ('b0000000-0000-0000-0000-000000000002',
   '11111111-1111-1111-1111-111111111111',
   'driver@test.com', 'managed-by-gotrue', 'driver')
on conflict (id) do nothing;

-- Usuario del tenant B (para probar aislamiento) -------------
insert into public.users (id, tenant_id, email, password_hash, role) values
  ('d0000000-0000-0000-0000-000000000004',
   '22222222-2222-2222-2222-222222222222',
   'driver-b@test.com', 'managed-by-gotrue', 'driver')
on conflict (id) do nothing;

-- Vehículo (tenant A) ----------------------------------------
insert into public.vehicles (id, tenant_id, license_plate, model) values
  ('c0000000-0000-0000-0000-000000000003',
   '11111111-1111-1111-1111-111111111111',
   '1234-ABC', 'Toyota Prius')
on conflict (id) do nothing;

-- Transacciones de ejemplo (tenant A, del driver) ------------
insert into public.transactions
  (id, tenant_id, user_id, vehicle_id, amount, category, type, payment_method, description) values
  ('e0000000-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111',
   'b0000000-0000-0000-0000-000000000002',
   'c0000000-0000-0000-0000-000000000003',
   45.50, 'carrera', 'income', 'card', 'Carrera aeropuerto'),
  ('e0000000-0000-0000-0000-000000000002',
   '11111111-1111-1111-1111-111111111111',
   'b0000000-0000-0000-0000-000000000002',
   'c0000000-0000-0000-0000-000000000003',
   60.00, 'combustible', 'expense', 'cash', 'Repostaje')
on conflict (id) do nothing;

-- Transacción del tenant B (NO debe verla el driver del tenant A)
insert into public.transactions
  (id, tenant_id, user_id, vehicle_id, amount, category, type, payment_method, description) values
  ('f0000000-0000-0000-0000-000000000001',
   '22222222-2222-2222-2222-222222222222',
   'd0000000-0000-0000-0000-000000000004',
   null,
   99.99, 'carrera', 'income', 'card', 'Transacción privada tenant B')
on conflict (id) do nothing;
