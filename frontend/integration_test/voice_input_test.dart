// Test de integración de la Fase 2 (entrada por voz + manual).
//
// Flujo (Whisper MOCKEADO vía mock_text — no depende de OpenAI):
//   - El endpoint /api/v1/transcribe exige JWT (401 sin token).
//   - Un driver transcribe+parsea una frase -> campos correctos.
//   - Segunda llamada idéntica -> servida desde caché.
//   - El driver inserta la transacción parseada en Supabase (RLS Fase 2).
//   - El Owner ve la transacción del driver.
//
// Ejecutar con el stack arriba:  dart test integration_test/voice_input_test.dart
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
  final ownerEmail = 'it.v.owner.$ts@test.com';
  final driverEmail = 'it.v.driver.$ts@test.com';
  const pwd = 'Owner12345!';

  test('Fase 2: transcripción mock, parseo, caché e inserción', () async {
    // Owner + tenant
    final owner = _client();
    final su = await owner.auth.signUp(email: ownerEmail, password: pwd, data: {'company_name': 'Flota Voz'});
    expect(su.session, isNotNull);
    final ownerToken = owner.auth.currentSession!.accessToken;

    // Invitar driver
    final inv = await http.post(
      Uri.parse('$backend/api/v1/drivers'),
      headers: {'Authorization': 'Bearer $ownerToken', 'Content-Type': 'application/json'},
      body: jsonEncode({'email': driverEmail, 'name': 'Chofer Voz'}),
    );
    expect(inv.statusCode, 201, reason: inv.body);
    final tempPwd = (jsonDecode(inv.body) as Map)['tempPassword'] as String;

    // Driver inicia sesión
    final driver = _client();
    final ds = await driver.auth.signInWithPassword(email: driverEmail, password: tempPwd);
    final driverToken = ds.session!.accessToken;
    final tenantId = (await driver.from('users').select('tenant_id').eq('id', ds.user!.id).single())['tenant_id'];

    // 1) Sin token -> 401
    final noAuth = await http.post(
      Uri.parse('$backend/api/v1/transcribe'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'mock_text': 'hola'}),
    );
    expect(noAuth.statusCode, 401);

    // 2) Transcribir + parsear (mock)
    const phrase = '35 con 50 de gasoil pagado con tarjeta';
    final t1 = await http.post(
      Uri.parse('$backend/api/v1/transcribe'),
      headers: {'Authorization': 'Bearer $driverToken', 'Content-Type': 'application/json'},
      body: jsonEncode({'mock_text': phrase}),
    );
    expect(t1.statusCode, 200, reason: t1.body);
    final b1 = jsonDecode(t1.body) as Map<String, dynamic>;
    expect(b1['text'], phrase);
    expect(b1['cached'], false);
    final parsed = b1['parsed'] as Map<String, dynamic>;
    expect(parsed['amount'], 35.5);
    expect(parsed['category'], 'gasoil');
    expect(parsed['type'], 'expense');
    expect(parsed['payment_method'], 'tarjeta');

    // 3) Segunda llamada idéntica -> caché
    final t2 = await http.post(
      Uri.parse('$backend/api/v1/transcribe'),
      headers: {'Authorization': 'Bearer $driverToken', 'Content-Type': 'application/json'},
      body: jsonEncode({'mock_text': phrase}),
    );
    expect((jsonDecode(t2.body) as Map)['cached'], true);

    // 4) El driver inserta la transacción parseada
    final inserted = await driver.from('transactions').insert({
      'tenant_id': tenantId,
      'user_id': ds.user!.id,
      'amount': parsed['amount'],
      'category': parsed['category'],
      'type': parsed['type'],
      'payment_method': parsed['payment_method'],
      'description': phrase,
    }).select().single();
    expect(inserted['id'], isNotNull);

    // 5) El Owner ve la transacción del driver
    final ownerTx = await owner.from('transactions').select().eq('id', inserted['id']);
    expect((ownerTx as List).length, 1, reason: 'el owner ve la transacción de su tenant');

    // 6) Carrera por voz: origen/destino/km/empresa + inserción y lectura
    const trip =
        'carrera de sants a la sagrera por 18 euros con tarjeta de movitaxi ciento cincuenta mil kilómetros';
    final t3 = await http.post(
      Uri.parse('$backend/api/v1/transcribe'),
      headers: {'Authorization': 'Bearer $driverToken', 'Content-Type': 'application/json'},
      body: jsonEncode({'mock_text': trip}),
    );
    expect(t3.statusCode, 200, reason: t3.body);
    final pt = (jsonDecode(t3.body) as Map<String, dynamic>)['parsed'] as Map<String, dynamic>;
    expect(pt['amount'], 18);
    expect(pt['type'], 'income');
    expect(pt['payment_method'], 'tarjeta');
    expect((pt['origin'] as String).toLowerCase(), 'sants');
    expect((pt['destination'] as String).toLowerCase(), 'la sagrera');
    expect(pt['odometer_km'], 150000);
    expect(pt['client_name'], 'Movitaxi');

    final trip1 = await driver.from('transactions').insert({
      'tenant_id': tenantId,
      'user_id': ds.user!.id,
      'amount': pt['amount'],
      'type': pt['type'],
      'payment_method': pt['payment_method'],
      'origin': pt['origin'],
      'destination': pt['destination'],
      'odometer_km': pt['odometer_km'],
      'client_name': pt['client_name'],
      'description': trip,
    }).select().single();
    expect(trip1['origin'], 'Sants');
    expect(trip1['client_name'], 'Movitaxi');
    expect(trip1['odometer_km'], 150000);

    // 7) Cliente particular: sin empresa nombrada -> client_name null
    final t4 = await http.post(
      Uri.parse('$backend/api/v1/transcribe'),
      headers: {'Authorization': 'Bearer $driverToken', 'Content-Type': 'application/json'},
      body: jsonEncode({'mock_text': 'cobré 12 con 50 de una carrera particular'}),
    );
    final pp = (jsonDecode(t4.body) as Map<String, dynamic>)['parsed'] as Map<String, dynamic>;
    expect(pp['amount'], 12.5);
    expect(pp['type'], 'income');
    expect(pp['client_name'], isNull);

    // Limpieza best-effort
    try {
      await admin.auth.admin.deleteUser(ds.user!.id);
      await admin.auth.admin.deleteUser(su.user!.id);
    } catch (_) {}
  });
}
