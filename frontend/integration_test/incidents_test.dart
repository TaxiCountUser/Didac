// Test de integración: incidencias / notas al jefe (migración 010) + RLS.
//
//   - driver1 escribe una nota; el Owner la ve (con autor) y la resuelve.
//   - driver2 NO ve la nota de driver1 (RLS).
//
// Ejecutar: dart test integration_test/incidents_test.dart
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

  test('incidencias: nota del chofer, vista del owner y RLS', () async {
    final owner = _client();
    final su = await owner.auth.signUp(
        email: 'it.inc.owner.$ts@test.com', password: 'Owner12345!', data: {'company_name': 'Flota INC'});
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

    final p1 = await invite('it.inc.d1.$ts@test.com', 'Chofer Uno');
    final p2 = await invite('it.inc.d2.$ts@test.com', 'Chofer Dos');
    final driver1 = _client();
    final d1s = await driver1.auth.signInWithPassword(email: 'it.inc.d1.$ts@test.com', password: p1);
    final driver2 = _client();
    final d2s = await driver2.auth.signInWithPassword(email: 'it.inc.d2.$ts@test.com', password: p2);

    // driver1 escribe una nota al jefe
    final inc = await driver1.from('incidents').insert({
      'tenant_id': tenantId,
      'user_id': d1s.user!.id,
      'kind': 'nota',
      'body': 'Ruido raro en la rueda derecha',
    }).select().single();
    expect(inc['status'], 'abierta');

    // El Owner la ve con el autor
    final ownerView = await owner
        .from('incidents')
        .select('*, users:user_id(name)')
        .eq('id', inc['id'])
        .single();
    expect((ownerView['users'] as Map)['name'], 'Chofer Uno');

    // driver2 NO la ve (RLS)
    final d2View = await driver2.from('incidents').select('id');
    expect((d2View as List).length, 0);

    // El Owner la marca resuelta
    final upd = await owner.from('incidents').update({'status': 'resuelta'}).eq('id', inc['id']).select();
    expect((upd as List).length, 1);

    // Limpieza best-effort
    try {
      await admin.auth.admin.deleteUser(d1s.user!.id);
      await admin.auth.admin.deleteUser(d2s.user!.id);
      await admin.auth.admin.deleteUser(su.user!.id);
    } catch (_) {}
  });
}
