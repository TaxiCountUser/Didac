// Test de integración: ubicación del conductor (migración 012) + RLS.
//   - driver1 hace upsert de su ubicación; el Owner la ve; driver2 no (RLS).
//   - driver2 NO puede escribir la ubicación de driver1.
// Ejecutar: dart test integration_test/driver_locations_test.dart
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

  test('ubicación del conductor: upsert, vista del owner y RLS', () async {
    final owner = _client();
    final su = await owner.auth.signUp(
        email: 'it.loc.owner.$ts@test.com', password: 'Owner12345!', data: {'company_name': 'Flota LOC'});
    final ownerToken = owner.auth.currentSession!.accessToken;
    final tenantId =
        (await owner.from('users').select('tenant_id').eq('id', su.user!.id).single())['tenant_id'];

    Future<String> invite(String email, String name) async {
      final res = await http.post(Uri.parse('$backend/api/v1/drivers'),
          headers: {'Authorization': 'Bearer $ownerToken', 'Content-Type': 'application/json'},
          body: jsonEncode({'email': email, 'name': name}));
      expect(res.statusCode, 201, reason: res.body);
      return (jsonDecode(res.body) as Map)['tempPassword'] as String;
    }

    final p1 = await invite('it.loc.d1.$ts@test.com', 'Chofer Uno');
    final p2 = await invite('it.loc.d2.$ts@test.com', 'Chofer Dos');
    final driver1 = _client();
    final d1s = await driver1.auth.signInWithPassword(email: 'it.loc.d1.$ts@test.com', password: p1);
    final driver2 = _client();
    final d2s = await driver2.auth.signInWithPassword(email: 'it.loc.d2.$ts@test.com', password: p2);

    // driver1 hace upsert de su ubicación
    await driver1.from('driver_locations').upsert({
      'user_id': d1s.user!.id,
      'tenant_id': tenantId,
      'lat': 41.3851,
      'lng': 2.1734,
      'accuracy': 12.0,
    });

    // El Owner la ve con el autor
    final ownerView = await owner
        .from('driver_locations')
        .select('*, users:user_id(name)')
        .eq('user_id', d1s.user!.id)
        .single();
    expect((ownerView['users'] as Map)['name'], 'Chofer Uno');
    expect((ownerView['lat'] as num).toDouble(), closeTo(41.3851, 0.0001));

    // driver2 NO la ve (RLS)
    final d2View = await driver2.from('driver_locations').select('user_id');
    expect((d2View as List).length, 0);

    // driver2 NO puede escribir la ubicación de driver1 (RLS)
    var blocked = false;
    try {
      await driver2.from('driver_locations').upsert({
        'user_id': d1s.user!.id, 'tenant_id': tenantId, 'lat': 0, 'lng': 0,
      });
    } catch (_) {
      blocked = true;
    }
    expect(blocked, true, reason: 'un conductor no puede escribir la ubicación de otro');

    try {
      await admin.auth.admin.deleteUser(d1s.user!.id);
      await admin.auth.admin.deleteUser(d2s.user!.id);
      await admin.auth.admin.deleteUser(su.user!.id);
    } catch (_) {}
  });
}
