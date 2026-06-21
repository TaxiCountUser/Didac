// E2E de staging — TaxiCount (Fase 6).
//
// Recorre el viaje completo del producto contra el stack (local/staging):
//   1. Registro de un nuevo Owner (crea tenant).
//   2. Contratación de plan Starter (efecto del webhook simulado con service_role).
//   3. Alta de 2 conductores + 2 vehículos.
//   4. Un conductor registra una transacción por VOZ (backend mock) y otra MANUAL.
//   5. El Owner visualiza el dashboard con filtros.
//   6. El Owner exporta Excel y PDF.
//   7. El Driver y el Owner cierran sesión.
//
// Dart puro, headless:  dart test integration_test/e2e_test.dart
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
  const pwd = 'Owner12345!';

  test('E2E: registro → suscripción → flota → transacciones → dashboard → export → logout',
      () async {
    // 1) Registro de Owner
    final owner = _client();
    final su = await owner.auth
        .signUp(email: 'e2e.owner.$ts@test.com', password: pwd, data: {'company_name': 'Flota E2E'});
    expect(su.session, isNotNull, reason: 'el Owner inicia sesión al registrarse');
    final ownerId = su.user!.id;
    final prof = await owner.from('users').select().eq('id', ownerId).single();
    expect(prof['role'], 'owner');
    final tenantId = prof['tenant_id'] as String;
    final ownerToken = owner.auth.currentSession!.accessToken;

    // 2) Contratación Starter (efecto del webhook de Stripe simulado)
    await admin.from('tenants').update({
      'subscription_status': 'active',
      'plan_id': 'starter',
      'drivers_limit': 2,
      'stripe_customer_id': 'cus_e2e_$ts',
      'stripe_subscription_id': 'sub_e2e_$ts',
    }).eq('id', tenantId);
    final billing =
        await owner.from('tenants').select('subscription_status, plan_id, drivers_limit').eq('id', tenantId).single();
    expect(billing['subscription_status'], 'active');
    expect(billing['drivers_limit'], 2);

    // 3) Alta de 2 conductores + 2 vehículos
    Future<Map<String, dynamic>> invite(String email, String name) async {
      final res = await http.post(
        Uri.parse('$backend/api/v1/drivers'),
        headers: {'Authorization': 'Bearer $ownerToken', 'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'name': name}),
      );
      expect(res.statusCode, 201, reason: 'alta de conductor: ${res.body}');
      return jsonDecode(res.body) as Map<String, dynamic>;
    }

    final d1 = await invite('e2e.d1.$ts@test.com', 'Ana E2E');
    final d2 = await invite('e2e.d2.$ts@test.com', 'Bruno E2E');
    final d1Id = d1['id'] as String;

    await owner.from('vehicles').insert([
      {'tenant_id': tenantId, 'license_plate': 'E2E-1-$ts', 'model': 'Toyota Prius'},
      {'tenant_id': tenantId, 'license_plate': 'E2E-2-$ts', 'model': 'Dacia Lodgy'},
    ]);
    final vehicles = await owner.from('vehicles').select();
    expect((vehicles as List).length, greaterThanOrEqualTo(2));

    // 4) Un conductor registra una transacción por VOZ y otra MANUAL
    final driver = _client();
    await driver.auth
        .signInWithPassword(email: 'e2e.d1.$ts@test.com', password: d1['tempPassword'] as String);
    final driverToken = driver.auth.currentSession!.accessToken;

    // 4a) Voz: backend transcribe (mock) + parsea
    final voiceRes = await http.post(
      Uri.parse('$backend/api/v1/transcribe'),
      headers: {'Authorization': 'Bearer $driverToken', 'Content-Type': 'application/json'},
      body: jsonEncode({'mock_text': 'treinta y cinco con cincuenta en gasolina con tarjeta'}),
    );
    expect(voiceRes.statusCode, 200, reason: 'transcripción: ${voiceRes.body}');
    final parsed = (jsonDecode(voiceRes.body) as Map<String, dynamic>)['parsed'] as Map<String, dynamic>;
    expect(parsed['amount'], 35.5, reason: 'el parser extrae el importe');
    await driver.from('transactions').insert({
      'tenant_id': tenantId,
      'user_id': d1Id,
      'amount': parsed['amount'],
      'type': parsed['type'],
      'category': parsed['category'],
      'payment_method': parsed['payment_method'],
      'description': 'voz',
    });

    // 4b) Manual
    await driver.from('transactions').insert({
      'tenant_id': tenantId,
      'user_id': d1Id,
      'amount': 120.0,
      'type': 'income',
      'category': 'ingreso_tarjeta',
      'payment_method': 'tarjeta',
      'description': 'manual',
    });

    // 5) El Owner visualiza el dashboard con filtros (por conductor d1)
    final now = DateTime.now();
    final from = DateTime(now.year, now.month).toIso8601String();
    final to = DateTime(now.year, now.month + 1).toIso8601String();
    final dash = await owner
        .from('transactions')
        .select('*, users:user_id(name, email)')
        .eq('tenant_id', tenantId)
        .eq('user_id', d1Id)
        .gte('created_at', from)
        .lt('created_at', to)
        .order('created_at', ascending: false);
    expect((dash as List).length, 2, reason: 'el dashboard ve las 2 transacciones de Ana');

    // 6) El Owner exporta Excel y PDF
    Future<http.Response> report(String fmt) => http.post(
          Uri.parse('$backend/api/v1/reports/$fmt'),
          headers: {'Authorization': 'Bearer $ownerToken', 'Content-Type': 'application/json'},
          body: jsonEncode({}),
        );
    final xlsx = await report('excel');
    expect(xlsx.statusCode, 200);
    expect([xlsx.bodyBytes[0], xlsx.bodyBytes[1]], [0x50, 0x4B], reason: 'xlsx (PK)');
    final pdf = await report('pdf');
    expect(pdf.statusCode, 200);
    expect(String.fromCharCodes(pdf.bodyBytes.sublist(0, 4)), '%PDF');

    // 7) Logout de Driver y Owner
    await driver.auth.signOut();
    expect(driver.auth.currentSession, isNull, reason: 'el Driver cierra sesión');
    await owner.auth.signOut();
    expect(owner.auth.currentSession, isNull, reason: 'el Owner cierra sesión');

    // Limpieza
    try {
      await admin.auth.admin.deleteUser(ownerId);
      await admin.auth.admin.deleteUser(d1Id);
      await admin.auth.admin.deleteUser(d2['id'] as String);
    } catch (_) {}
  }, timeout: const Timeout(Duration(seconds: 90)));
}
