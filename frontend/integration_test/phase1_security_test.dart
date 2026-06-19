// Test de integración de la Fase 1 (seguridad + jerarquía).
//
// Ejecuta el flujo completo contra el stack local (docker compose up):
//   a) Registro de un Owner  -> el trigger crea tenant + perfil 'owner'.
//   b) El Owner crea un vehículo.
//   c) El Owner invita a un driver (vía backend Fastify + service_role).
//   d) El driver inicia sesión y NO puede ver vehículos (RLS).
//   e) El Owner sí ve su vehículo.
//   f) Aislamiento entre tenants: un Owner no ve vehículos de otro.
//
// Usa el cliente Dart puro de Supabase (sin canales de plataforma),
// por lo que corre con:  flutter test integration_test/phase1_security_test.dart
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

// Flujo implicit: sin almacenamiento async (apto para tests de VM).
const _authOpts = AuthClientOptions(authFlowType: AuthFlowType.implicit);

SupabaseClient _client() => SupabaseClient(url, anonKey, authOptions: _authOpts);

void main() {
  final admin = SupabaseClient(url, serviceKey, authOptions: _authOpts);
  final ts = DateTime.now().millisecondsSinceEpoch;
  final ownerEmail = 'it.owner.$ts@test.com';
  final ownerBEmail = 'it.ownerb.$ts@test.com';
  final driverEmail = 'it.driver.$ts@test.com';
  const pwd = 'Owner12345!';

  test('Fase 1: auth, jerarquía y aislamiento RLS', () async {
    // a) Registro de Owner A
    final ownerA = _client();
    final signUpA = await ownerA.auth.signUp(
      email: ownerEmail,
      password: pwd,
      data: {'company_name': 'Flota A'},
    );
    expect(signUpA.session, isNotNull, reason: 'signUp debe iniciar sesión (autoconfirm)');
    final ownerAId = signUpA.user!.id;

    // El trigger debe haber creado el perfil 'owner' con tenant
    final profA = await ownerA.from('users').select().eq('id', ownerAId).single();
    expect(profA['role'], 'owner');
    expect(profA['tenant_id'], isNotNull);
    final tenantA = profA['tenant_id'] as String;

    // b) El Owner crea un vehículo
    await ownerA.from('vehicles').insert({
      'tenant_id': tenantA,
      'license_plate': 'IT-$ts',
      'model': 'Test Car',
    });

    // c) El Owner invita a un driver vía backend
    final token = ownerA.auth.currentSession!.accessToken;
    final res = await http.post(
      Uri.parse('$backend/api/v1/drivers'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: jsonEncode({'email': driverEmail, 'name': 'Conductor IT'}),
    );
    expect(res.statusCode, 201, reason: 'invitar driver debe devolver 201: ${res.body}');
    final invite = jsonDecode(res.body) as Map<String, dynamic>;
    final tempPwd = invite['tempPassword'] as String;
    expect(invite['tenant_id'], tenantA, reason: 'driver en el tenant del owner');

    // d) El driver inicia sesión y NO puede ver vehículos
    final driver = _client();
    final driverSignIn = await driver.auth.signInWithPassword(
      email: driverEmail,
      password: tempPwd,
    );
    expect(driverSignIn.session, isNotNull, reason: 'driver debe poder iniciar sesión');

    final driverProfile =
        await driver.from('users').select().eq('id', driverSignIn.user!.id).single();
    expect(driverProfile['role'], 'driver');

    final driverVehicles = await driver.from('vehicles').select();
    expect((driverVehicles as List), isEmpty,
        reason: 'RLS: un driver NO debe ver vehículos');

    // e) El Owner sí ve su vehículo
    final ownerVehicles = await ownerA.from('vehicles').select();
    expect((ownerVehicles as List).length, greaterThanOrEqualTo(1),
        reason: 'el owner debe ver su vehículo');
    expect(ownerVehicles.every((v) => v['tenant_id'] == tenantA), isTrue,
        reason: 'el owner solo ve vehículos de su tenant');

    // f) Aislamiento entre tenants: Owner B no ve el vehículo de A
    final ownerB = _client();
    final signUpB = await ownerB.auth.signUp(
      email: ownerBEmail,
      password: pwd,
      data: {'company_name': 'Flota B'},
    );
    final ownerBId = signUpB.user!.id;
    final ownerBVehicles = await ownerB.from('vehicles').select();
    expect((ownerBVehicles as List), isEmpty,
        reason: 'Owner B no debe ver vehículos de otro tenant');

    // Limpieza (best-effort)
    try {
      await admin.auth.admin.deleteUser(ownerAId);
      await admin.auth.admin.deleteUser(ownerBId);
      await admin.auth.admin.deleteUser(driverSignIn.user!.id);
    } catch (_) {}
  });
}
