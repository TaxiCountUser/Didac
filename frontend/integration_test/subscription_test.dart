// Test de integración de la Fase 4 (SubscriptionBillingLoop).
//
// Valida, contra el stack local, la monetización SIN depender de Stripe real:
//   a) Owner nuevo: estado por defecto 'trialing' (puede operar).
//   b) "Contratación" del plan Starter: se simula el efecto del webhook
//      (service_role fija plan_id/drivers_limit/estado), como sanciona la spec.
//   c) Límite de conductores (Starter = 2): el 3.º falla con 403.
//   d) Impago: con subscription_status='past_due', el Driver NO puede crear
//      transacciones (bloqueo por RLS); al reactivar, vuelve a poder.
//
// Dart puro -> headless con:  dart test integration_test/subscription_test.dart
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
  final ownerEmail = 'sub.owner.$ts@test.com';
  const pwd = 'Owner12345!';

  test('Fase 4: límite de plan, simulación de webhook y bloqueo por impago',
      () async {
    // ---- a) Owner nuevo: estado por defecto 'trialing' ----
    final owner = _client();
    final su = await owner.auth
        .signUp(email: ownerEmail, password: pwd, data: {'company_name': 'Flota Sub'});
    expect(su.session, isNotNull);
    final ownerId = su.user!.id;
    final prof = await owner.from('users').select().eq('id', ownerId).single();
    final tenantId = prof['tenant_id'] as String;
    final ownerToken = owner.auth.currentSession!.accessToken;

    final t0 = await owner.from('tenants').select('subscription_status, drivers_limit').eq('id', tenantId).single();
    expect(t0['subscription_status'], 'trialing', reason: 'nuevo tenant en periodo de prueba');

    // ---- b) "Contratación" del plan Starter (efecto del webhook simulado) ----
    await admin.from('tenants').update({
      'subscription_status': 'active',
      'plan_id': 'starter',
      'drivers_limit': 2,
      'stripe_customer_id': 'cus_sub_$ts',
      'stripe_subscription_id': 'sub_sub_$ts',
    }).eq('id', tenantId);

    Future<http.Response> invite(String email) => http.post(
          Uri.parse('$backend/api/v1/drivers'),
          headers: {'Authorization': 'Bearer $ownerToken', 'Content-Type': 'application/json'},
          body: jsonEncode({'email': email, 'name': 'Driver $email'}),
        );

    // ---- c) Límite de conductores: 2 OK, el 3.º falla ----
    final r1 = await invite('sub.d1.$ts@test.com');
    expect(r1.statusCode, 201, reason: 'driver 1: ${r1.body}');
    final r2 = await invite('sub.d2.$ts@test.com');
    expect(r2.statusCode, 201, reason: 'driver 2: ${r2.body}');
    final r3 = await invite('sub.d3.$ts@test.com');
    expect(r3.statusCode, 403, reason: 'driver 3 debe superar el límite: ${r3.body}');
    expect((jsonDecode(r3.body) as Map)['error'].toString(),
        contains('límite de conductores'));

    // Datos del driver 1 para iniciar sesión
    final d1Pwd = (jsonDecode(r1.body) as Map)['tempPassword'] as String;
    final d1Email = 'sub.d1.$ts@test.com';
    final driver = _client();
    final dSignIn = await driver.auth.signInWithPassword(email: d1Email, password: d1Pwd);
    final d1Id = dSignIn.user!.id;

    Future<Object?> tryInsert() async {
      try {
        await driver.from('transactions').insert({
          'tenant_id': tenantId,
          'user_id': d1Id,
          'amount': 12.5,
          'type': 'expense',
          'category': 'otros',
          'payment_method': 'efectivo',
        });
        return null; // OK
      } catch (e) {
        return e; // bloqueado
      }
    }

    // Con suscripción activa, el driver SÍ puede registrar.
    expect(await tryInsert(), isNull, reason: 'activa: el driver puede insertar');

    // ---- d) Impago: bloqueo de escritura por RLS ----
    await admin.from('tenants').update({'subscription_status': 'past_due'}).eq('id', tenantId);
    final blocked = await tryInsert();
    expect(blocked, isNotNull, reason: 'past_due: el insert debe ser rechazado por RLS');

    // El Driver sigue pudiendo LEER su histórico aunque esté impagado.
    final readWhileBlocked = await driver.from('transactions').select();
    expect(readWhileBlocked, isA<List>());

    // ---- Reactivación: vuelve a poder escribir ----
    await admin.from('tenants').update({'subscription_status': 'active'}).eq('id', tenantId);
    expect(await tryInsert(), isNull, reason: 'reactivada: el driver vuelve a insertar');

    // ---- Limpieza ----
    try {
      await admin.auth.admin.deleteUser(ownerId);
      await admin.auth.admin.deleteUser(d1Id);
      for (final e in ['sub.d2.$ts@test.com']) {
        final u = await admin.from('users').select('id').eq('email', e).maybeSingle();
        if (u != null) await admin.auth.admin.deleteUser(u['id'] as String);
      }
    } catch (_) {}
  }, timeout: const Timeout(Duration(seconds: 60)));
}
