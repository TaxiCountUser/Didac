// Test de integración: asignación conductor <-> vehículo (migración 008) + RLS.
//
// Flujo (stack local arriba):
//   - Owner crea 2 vehículos e invita 2 conductores.
//   - Owner asigna vehículo1 a driver1 (driver_vehicles).
//   - driver1 ve su asignación; driver2 NO la ve (RLS).
//   - driver2 NO puede asignarse vehículos (RLS de escritura solo Owner).
//   - driver1 registra una transacción con vehicle_id; el Owner la ve con vehículo.
//
// Ejecutar: dart test integration_test/driver_vehicles_test.dart
import 'dart:convert';
import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

const url = 'http://localhost:54321';
const backend = 'http://localhost:3000';
const anonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlLWRlbW8iLCJpYXQiOjE3MDAwMDAwMDAsImV4cCI6MjAwMDAwMDAwMH0.ZxBhVEYye2lqm5NDdkey-JP6uTHcqvZriXUoBtyQniY';
const serviceKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UtZGVtbyIsImlhdCI6MTcwMDAwMDAwMCwiZXhwIjoyMDAwMDAwMDAwfQ.8T3kmJ5SaqY3bVmU02ZJ4MIoHe5z7R4qQ4T9VqJA8hk';

const _authOpts = AuthClientOptions(authFlowType: AuthFlowType.implicit);
SupabaseClient _client() => SupabaseClient(url, anonKey, authOptions: _authOpts);

void main() {
  final admin = SupabaseClient(url, serviceKey, authOptions: _authOpts);
  final ts = DateTime.now().millisecondsSinceEpoch;

  test('asignación coche↔chofer + RLS + vehículo en transacción', () async {
    // Owner + tenant
    final owner = _client();
    final su = await owner.auth.signUp(
        email: 'it.dv.owner.$ts@test.com', password: 'Owner12345!', data: {'company_name': 'Flota DV'});
    expect(su.session, isNotNull);
    final ownerToken = owner.auth.currentSession!.accessToken;
    final tenantId =
        (await owner.from('users').select('tenant_id').eq('id', su.user!.id).single())['tenant_id'];

    // 2 vehículos (owner write)
    final v1 = await owner.from('vehicles').insert(
        {'tenant_id': tenantId, 'license_plate': 'DV-1-$ts', 'model': 'Prius'}).select().single();
    final v2 = await owner.from('vehicles').insert(
        {'tenant_id': tenantId, 'license_plate': 'DV-2-$ts', 'model': 'Ioniq'}).select().single();

    // 2 conductores (vía backend)
    Future<String> invite(String email, String name) async {
      final res = await http.post(Uri.parse('$backend/api/v1/drivers'),
          headers: {'Authorization': 'Bearer $ownerToken', 'Content-Type': 'application/json'},
          body: jsonEncode({'email': email, 'name': name}));
      expect(res.statusCode, 201, reason: res.body);
      return (jsonDecode(res.body) as Map)['tempPassword'] as String;
    }
    final p1 = await invite('it.dv.d1.$ts@test.com', 'Driver Uno');
    final p2 = await invite('it.dv.d2.$ts@test.com', 'Driver Dos');

    final driver1 = _client();
    final d1s = await driver1.auth.signInWithPassword(email: 'it.dv.d1.$ts@test.com', password: p1);
    final d1 = d1s.user!.id;
    final driver2 = _client();
    final d2s = await driver2.auth.signInWithPassword(email: 'it.dv.d2.$ts@test.com', password: p2);

    // Owner asigna v1 a driver1
    await owner.from('driver_vehicles').insert(
        {'tenant_id': tenantId, 'user_id': d1, 'vehicle_id': v1['id']});

    // driver1 ve su asignación
    final seenByD1 = await driver1.from('driver_vehicles').select('vehicle_id');
    expect((seenByD1 as List).length, 1);
    expect(seenByD1.first['vehicle_id'], v1['id']);

    // driver1 puede LEER el vehículo asignado vía el join que usa la app
    // (myVehicles -> vehiclesForDriver). Antes de la migración 014 esto
    // devolvía null por RLS y el selector salía vacío.
    final myVeh = await driver1
        .from('driver_vehicles')
        .select('vehicle_id, vehicles:vehicle_id(id, license_plate, model)')
        .eq('user_id', d1);
    final embedded = (myVeh as List).first['vehicles'] as Map?;
    expect(embedded, isNotNull, reason: 'el chofer debe poder leer su vehículo asignado');
    expect(embedded!['license_plate'], 'DV-1-$ts');

    // pero NO puede leer un vehículo que NO le han asignado (v2)
    final notMine = await driver1.from('vehicles').select('id').eq('id', v2['id']);
    expect((notMine as List).length, 0, reason: 'el chofer no ve vehículos no asignados');

    // driver2 NO ve la asignación de driver1 (RLS)
    final seenByD2 = await driver2.from('driver_vehicles').select('vehicle_id');
    expect((seenByD2 as List).length, 0, reason: 'driver2 no debe ver asignaciones ajenas');

    // driver2 NO puede asignarse vehículos (RLS de escritura solo Owner)
    var blocked = false;
    try {
      await driver2.from('driver_vehicles').insert(
          {'tenant_id': tenantId, 'user_id': d2s.user!.id, 'vehicle_id': v2['id']});
    } catch (_) {
      blocked = true;
    }
    expect(blocked, true, reason: 'un conductor no puede auto-asignarse vehículos');

    // driver1 registra una transacción con vehicle_id
    final tx = await driver1.from('transactions').insert({
      'tenant_id': tenantId,
      'user_id': d1,
      'vehicle_id': v1['id'],
      'amount': 22.5,
      'type': 'income',
      'client_name': 'Gitaxi',
    }).select().single();
    expect(tx['vehicle_id'], v1['id']);

    // El Owner la ve con el vehículo unido
    final ownerView = await owner
        .from('transactions')
        .select('*, vehicles:vehicle_id(license_plate)')
        .eq('id', tx['id'])
        .single();
    expect((ownerView['vehicles'] as Map)['license_plate'], 'DV-1-$ts');

    // Odómetro: driver1 apunta km; el Owner lo ve, driver2 no (RLS).
    await driver1.from('odometer_readings').insert(
        {'tenant_id': tenantId, 'vehicle_id': v1['id'], 'user_id': d1, 'reading_km': 123456});
    final ownerKm = await owner.from('odometer_readings').select('reading_km').eq('vehicle_id', v1['id']);
    expect((ownerKm as List).length, 1);
    expect(ownerKm.first['reading_km'], 123456);
    final d2Km = await driver2.from('odometer_readings').select('id');
    expect((d2Km as List).length, 0, reason: 'driver2 no ve lecturas ajenas');

    // Limpieza best-effort
    try {
      await admin.auth.admin.deleteUser(d1);
      await admin.auth.admin.deleteUser(d2s.user!.id);
      await admin.auth.admin.deleteUser(su.user!.id);
    } catch (_) {}
  });
}
