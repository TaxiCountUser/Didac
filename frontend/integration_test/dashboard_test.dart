// Test de integración de la Fase 3 (DashboardSyncLoop).
//
// Valida, contra el stack local (docker compose up), la capa de datos que
// alimenta el dashboard del Owner y el historial del Driver:
//   a) KPIs del Owner correctos con datos de prueba conocidos.
//   b) Filtro por conductor: reduce la lista y recalcula los KPIs.
//   c) "Realtime": una transacción nueva aparece en la consulta del Owner en
//      < 2 s (polling cada 250 ms, como sanciona la especificación; en la app
//      el dashboard usa supabase.channel() — ver owner_dashboard_screen.dart).
//   d) El Driver solo ve sus propias transacciones (RLS).
//
// Es Dart puro (cliente Supabase, sin widgets) -> corre headless con:
//   dart test integration_test/dashboard_test.dart
//
// Autocontenido: crea owner + 2 drivers + transacciones y limpia al final.
import 'dart:async';
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

// ---- Réplica de la lógica de DataService (mismas queries que las pantallas) ----

const _txSelect =
    '*, users:user_id(name, email), vehicles:vehicle_id(license_plate, model)';

Future<List<Map<String, dynamic>>> listTransactions(
  SupabaseClient c, {
  String? userId,
  String? vehicleId,
  required DateTime from,
  required DateTime to,
  int offset = 0,
  int limit = 20,
}) async {
  var q = c.from('transactions').select(_txSelect);
  if (userId != null) q = q.eq('user_id', userId);
  if (vehicleId != null) q = q.eq('vehicle_id', vehicleId);
  q = q.gte('created_at', from.toIso8601String()).lt('created_at', to.toIso8601String());
  final data =
      await q.order('created_at', ascending: false).range(offset, offset + limit - 1);
  return (data as List).cast<Map<String, dynamic>>();
}

({double income, double expense, Map<String, double> byCat}) summarize(
    List<Map<String, dynamic>> rows) {
  double income = 0, expense = 0;
  final byCat = <String, double>{};
  for (final r in rows) {
    final amount = (r['amount'] as num).toDouble();
    if (r['type'] == 'income') {
      income += amount;
    } else {
      expense += amount;
      final cat = (r['category'] as String?) ?? 'otros';
      byCat[cat] = (byCat[cat] ?? 0) + amount;
    }
  }
  return (income: income, expense: expense, byCat: byCat);
}

void main() {
  final admin = SupabaseClient(url, serviceKey, authOptions: _authOpts);
  final ts = DateTime.now().millisecondsSinceEpoch;
  final ownerEmail = 'dash.owner.$ts@test.com';
  final driver1Email = 'dash.d1.$ts@test.com';
  final driver2Email = 'dash.d2.$ts@test.com';
  const pwd = 'Owner12345!';

  final now = DateTime.now();
  final monthFrom = DateTime(now.year, now.month);
  final monthTo = DateTime(now.year, now.month + 1);

  test('Fase 3: dashboard del Owner, filtros, realtime y RLS del Driver',
      () async {
    // ---- Setup: Owner + 2 drivers ----
    final owner = _client();
    final signUp = await owner.auth.signUp(
      email: ownerEmail,
      password: pwd,
      data: {'company_name': 'Flota Dashboard'},
    );
    expect(signUp.session, isNotNull);
    final ownerId = signUp.user!.id;
    final prof = await owner.from('users').select().eq('id', ownerId).single();
    final tenantId = prof['tenant_id'] as String;
    final ownerToken = owner.auth.currentSession!.accessToken;

    Future<String> invite(String email, String name) async {
      final res = await http.post(
        Uri.parse('$backend/api/v1/drivers'),
        headers: {'Authorization': 'Bearer $ownerToken', 'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'name': name}),
      );
      expect(res.statusCode, 201, reason: 'invitar driver: ${res.body}');
      return (jsonDecode(res.body) as Map<String, dynamic>)['tempPassword'] as String;
    }

    final d1Pwd = await invite(driver1Email, 'Ana Conductora');
    final d2Pwd = await invite(driver2Email, 'Bruno Conductor');

    final d1 = _client();
    final d2 = _client();
    final d1Sess = await d1.auth.signInWithPassword(email: driver1Email, password: d1Pwd);
    final d2Sess = await d2.auth.signInWithPassword(email: driver2Email, password: d2Pwd);
    final d1Id = d1Sess.user!.id;
    final d2Id = d2Sess.user!.id;

    // ---- Datos conocidos (cada driver inserta los suyos, respetando RLS) ----
    Future<void> insertTx(SupabaseClient c, String uid, double amount, String type,
        String? cat, String pay) async {
      await c.from('transactions').insert({
        'tenant_id': tenantId,
        'user_id': uid,
        'amount': amount,
        'type': type,
        'category': cat,
        'payment_method': pay,
      });
    }

    await insertTx(d1, d1Id, 100.0, 'income', 'ingreso_tarjeta', 'tarjeta'); // ingreso
    await insertTx(d1, d1Id, 30.0, 'expense', 'gasolina', 'tarjeta'); // gasto
    await insertTx(d2, d2Id, 20.0, 'expense', 'peaje', 'efectivo'); // gasto

    // ---- a) KPIs del Owner correctos (todo el tenant, periodo = mes) ----
    final allRows = await listTransactions(owner, from: monthFrom, to: monthTo, limit: 100);
    final all = summarize(allRows);
    expect(all.income, 100.0, reason: 'ingresos totales');
    expect(all.expense, 50.0, reason: 'gastos totales (30 + 20)');
    expect(all.income - all.expense, 50.0, reason: 'balance neto');
    expect(all.byCat['gasolina'], 30.0);
    expect(all.byCat['peaje'], 20.0);
    expect(allRows.length, 3, reason: 'el owner ve las 3 del tenant');

    // ---- b) Filtro por conductor (driver1): reduce lista y recalcula KPIs ----
    final d1Rows =
        await listTransactions(owner, userId: d1Id, from: monthFrom, to: monthTo, limit: 100);
    final d1Sum = summarize(d1Rows);
    expect(d1Rows.length, 2, reason: 'solo las 2 de driver1');
    expect(d1Sum.income, 100.0);
    expect(d1Sum.expense, 30.0);
    expect(d1Sum.byCat.containsKey('peaje'), isFalse,
        reason: 'el peaje es de driver2, no debe aparecer');

    // ---- c) "Realtime": una nueva tx aparece en < 2 s (polling) ----
    await insertTx(d2, d2Id, 15.0, 'expense', 'parking', 'efectivo');
    final sw = Stopwatch()..start();
    bool seen = false;
    while (sw.elapsedMilliseconds < 2000) {
      final rows = await listTransactions(owner, from: monthFrom, to: monthTo, limit: 100);
      if (rows.any((r) =>
          r['category'] == 'parking' && (r['amount'] as num).toDouble() == 15.0)) {
        seen = true;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 250));
    }
    expect(seen, isTrue, reason: 'la nueva transacción debe aparecer en < 2 s');

    // El nombre del conductor llega embebido (para el SnackBar/lista del Owner)
    final latest = await listTransactions(owner, from: monthFrom, to: monthTo, limit: 1);
    expect((latest.first['users'] as Map)['name'], 'Bruno Conductor');

    // ---- d) RLS: el Driver solo ve sus propias transacciones ----
    final d1Visible = await listTransactions(d1, from: monthFrom, to: monthTo, limit: 100);
    expect(d1Visible.every((r) => r['user_id'] == d1Id), isTrue,
        reason: 'driver1 no debe ver transacciones de otros');
    expect(d1Visible.length, 2);

    final d2Visible = await listTransactions(d2, from: monthFrom, to: monthTo, limit: 100);
    expect(d2Visible.every((r) => r['user_id'] == d2Id), isTrue);
    expect(d2Visible.length, 2, reason: 'driver2: peaje + parking');

    // ---- Limpieza (cascade borra users + transactions del tenant) ----
    try {
      await admin.auth.admin.deleteUser(ownerId);
      await admin.auth.admin.deleteUser(d1Id);
      await admin.auth.admin.deleteUser(d2Id);
    } catch (_) {}
  });

  test('Fase 3: sync en tiempo real por WebSocket (supabase.channel)', () async {
    // Requiere el servidor de Realtime (perfil "realtime"). Si no está
    // levantado, el canal no llega a "subscribed" y el test se marca como
    // omitido (la app y el resto de la suite siguen funcionando sin él).
    final owner = _client();
    final email = 'dash.rt.$ts@test.com';
    final su = await owner.auth
        .signUp(email: email, password: pwd, data: {'company_name': 'Flota RT'});
    final ownerId = su.user!.id;
    final prof = await owner.from('users').select().eq('id', ownerId).single();
    final tenantId = prof['tenant_id'] as String;
    owner.realtime.setAuth(owner.auth.currentSession!.accessToken);

    final subscribed = Completer<bool>();
    final event = Completer<Map<String, dynamic>>();
    final ch = owner.channel('it-tx-$tenantId');
    ch.onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'transactions',
      filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq, column: 'tenant_id', value: tenantId),
      callback: (p) {
        if (!event.isCompleted) event.complete(p.newRecord);
      },
    ).subscribe((status, err) {
      if (status == RealtimeSubscribeStatus.subscribed && !subscribed.isCompleted) {
        subscribed.complete(true);
      } else if (status == RealtimeSubscribeStatus.channelError &&
          !subscribed.isCompleted) {
        subscribed.complete(false);
      }
    });

    final isUp = await subscribed.future
        .timeout(const Duration(seconds: 5), onTimeout: () => false);
    if (!isUp) {
      await owner.removeChannel(ch);
      try {
        await admin.auth.admin.deleteUser(ownerId);
      } catch (_) {}
      markTestSkipped(
          'Servidor de Realtime no disponible (arranca con --profile realtime).');
      return;
    }

    final sw = Stopwatch()..start();
    await owner.from('transactions').insert({
      'tenant_id': tenantId,
      'user_id': ownerId,
      'amount': 77.0,
      'type': 'expense',
      'category': 'otros',
      'payment_method': 'tarjeta',
    });
    final rec = await event.future.timeout(const Duration(seconds: 3),
        onTimeout: () => <String, dynamic>{});
    expect(rec['amount'], 77.0, reason: 'el INSERT debe llegar por WebSocket');
    expect(sw.elapsedMilliseconds, lessThan(2000),
        reason: 'el evento realtime debe llegar en < 2 s');

    await owner.removeChannel(ch);
    try {
      await admin.auth.admin.deleteUser(ownerId);
    } catch (_) {}
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('Fase 3: paginación con .range() (20 por página)', () async {
    // Owner con > 20 transacciones para verificar el troceado.
    final owner = _client();
    final email = 'dash.page.$ts@test.com';
    final su = await owner.auth.signUp(email: email, password: pwd, data: {'company_name': 'Flota Page'});
    final ownerId = su.user!.id;
    final prof = await owner.from('users').select().eq('id', ownerId).single();
    final tenantId = prof['tenant_id'] as String;

    final rows = List.generate(25, (i) => {
          'tenant_id': tenantId,
          'user_id': ownerId,
          'amount': (i + 1).toDouble(),
          'type': 'expense',
          'category': 'otros',
          'payment_method': 'tarjeta',
        });
    await owner.from('transactions').insert(rows);

    final monthFrom2 = DateTime(now.year, now.month);
    final monthTo2 = DateTime(now.year, now.month + 1);
    final page1 = await listTransactions(owner, from: monthFrom2, to: monthTo2, offset: 0, limit: 20);
    final page2 = await listTransactions(owner, from: monthFrom2, to: monthTo2, offset: 20, limit: 20);
    expect(page1.length, 20, reason: 'primera página completa');
    expect(page2.length, 5, reason: 'segunda página con el resto');
    // Sin solapamiento entre páginas.
    final ids1 = page1.map((r) => r['id']).toSet();
    final ids2 = page2.map((r) => r['id']).toSet();
    expect(ids1.intersection(ids2), isEmpty);

    try {
      await admin.auth.admin.deleteUser(ownerId);
    } catch (_) {}
  });
}
