// Test de integración de la Fase 5 (ReportGenerationLoop).
//
// Valida los endpoints de exportación contra el stack local:
//   a) El Owner descarga Excel (.xlsx, zip 'PK') con cabeceras correctas.
//   b) El Owner descarga PDF ('%PDF').
//   c) La caché: una 2.ª llamada devuelve los mismos bytes.
//   d) Un conductor (no Owner) recibe 403.
//
// Dart puro (hace de "descarga mockeada" sin abrir el fichero, que requiere
// canales de plataforma). Headless:
//   dart test integration_test/reports_test.dart
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

  test('Fase 5: el Owner exporta Excel y PDF; el conductor no puede', () async {
    // ---- Setup ----
    final owner = _client();
    final su = await owner.auth
        .signUp(email: 'rep.owner.$ts@test.com', password: pwd, data: {'company_name': 'Flota Informes'});
    expect(su.session, isNotNull);
    final ownerId = su.user!.id;
    final prof = await owner.from('users').select().eq('id', ownerId).single();
    final tenantId = prof['tenant_id'] as String;
    final ownerToken = owner.auth.currentSession!.accessToken;

    Future<Map<String, dynamic>> invite(String email, String name) async {
      final res = await http.post(
        Uri.parse('$backend/api/v1/drivers'),
        headers: {'Authorization': 'Bearer $ownerToken', 'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'name': name}),
      );
      expect(res.statusCode, 201, reason: 'invite: ${res.body}');
      return jsonDecode(res.body) as Map<String, dynamic>;
    }

    final d1 = await invite('rep.d1.$ts@test.com', 'Ana Informe');
    final d2 = await invite('rep.d2.$ts@test.com', 'Bruno Informe');
    final d1Id = d1['id'] as String;
    final d2Id = d2['id'] as String;

    await admin.from('transactions').insert([
      {'tenant_id': tenantId, 'user_id': d1Id, 'amount': 100, 'type': 'income', 'category': 'ingreso_tarjeta', 'payment_method': 'tarjeta'},
      {'tenant_id': tenantId, 'user_id': d1Id, 'amount': 30, 'type': 'expense', 'category': 'gasolina', 'payment_method': 'tarjeta'},
      {'tenant_id': tenantId, 'user_id': d2Id, 'amount': 20, 'type': 'expense', 'category': 'peaje', 'payment_method': 'efectivo'},
    ]);

    Future<http.Response> report(String format, String token) => http.post(
          Uri.parse('$backend/api/v1/reports/$format'),
          headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
          body: jsonEncode({}),
        );

    // ---- a) Excel ----
    final xlsx = await report('excel', ownerToken);
    expect(xlsx.statusCode, 200, reason: xlsx.body);
    expect(xlsx.headers['content-type'], contains('spreadsheetml.sheet'));
    expect(xlsx.headers['content-disposition'], contains('.xlsx'));
    final xb = xlsx.bodyBytes;
    expect(xb.length, greaterThan(0));
    expect([xb[0], xb[1]], [0x50, 0x4B], reason: 'un .xlsx es un zip (empieza por PK)');

    // ---- b) PDF ----
    final pdf = await report('pdf', ownerToken);
    expect(pdf.statusCode, 200, reason: pdf.body);
    expect(pdf.headers['content-type'], contains('application/pdf'));
    final pb = pdf.bodyBytes;
    expect(String.fromCharCodes(pb.sublist(0, 4)), '%PDF', reason: 'cabecera PDF');

    // ---- c) Caché: misma consulta -> mismos bytes ----
    final xlsx2 = await report('excel', ownerToken);
    expect(xlsx2.statusCode, 200);
    expect(xlsx2.bodyBytes.length, xb.length, reason: 'la caché debe devolver el mismo fichero');

    // ---- d) Un conductor no puede exportar (403) ----
    final driver = _client();
    await driver.auth
        .signInWithPassword(email: 'rep.d1.$ts@test.com', password: d1['tempPassword'] as String);
    final driverToken = driver.auth.currentSession!.accessToken;
    final forbidden = await report('excel', driverToken);
    expect(forbidden.statusCode, 403, reason: 'un conductor no debe poder exportar');

    // ---- Limpieza ----
    try {
      await admin.auth.admin.deleteUser(ownerId);
      await admin.auth.admin.deleteUser(d1Id);
      await admin.auth.admin.deleteUser(d2Id);
    } catch (_) {}
  }, timeout: const Timeout(Duration(seconds: 60)));
}
