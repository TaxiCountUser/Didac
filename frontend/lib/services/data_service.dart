import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../models/profile.dart';

/// Resumen financiero de un conjunto de transacciones.
class TxSummary {
  final double income;
  final double expense;
  final Map<String, double> expenseByCategory;
  const TxSummary({
    required this.income,
    required this.expense,
    required this.expenseByCategory,
  });
  double get balance => income - expense;
  factory TxSummary.empty() =>
      const TxSummary(income: 0, expense: 0, expenseByCategory: {});
}

/// Acceso a datos vía Supabase (respetando RLS) y al backend Fastify.
class DataService {
  SupabaseClient get _c => Supabase.instance.client;

  /// Cliente Supabase (para suscripciones realtime desde las pantallas).
  SupabaseClient get client => _c;

  Future<Profile?> fetchMyProfile() async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) return null;
    final row = await _c.from('users').select().eq('id', uid).maybeSingle();
    return row == null ? null : Profile.fromMap(row);
  }

  // ---------------- Vehículos ----------------
  Future<List<Map<String, dynamic>>> listVehicles() async {
    final data = await _c.from('vehicles').select().order('created_at');
    return (data as List).cast<Map<String, dynamic>>();
  }

  Future<void> addVehicle({
    required String tenantId,
    required String licensePlate,
    String? model,
  }) async {
    await _c.from('vehicles').insert({
      'tenant_id': tenantId,
      'license_plate': licensePlate,
      'model': model,
    });
  }

  Future<void> deleteVehicle(String id) async {
    await _c.from('vehicles').delete().eq('id', id);
  }

  // ---------------- Conductores ----------------
  Future<List<Map<String, dynamic>>> listDrivers() async {
    final data =
        await _c.from('users').select().eq('role', 'driver').order('created_at');
    return (data as List).cast<Map<String, dynamic>>();
  }

  /// Invita a un conductor a través del backend (service_role).
  /// Devuelve la contraseña temporal (en desarrollo).
  Future<String> inviteDriver({required String email, String? name}) async {
    final token = _c.auth.currentSession?.accessToken;
    if (token == null) throw Exception('No hay sesión activa');

    final res = await http.post(
      Uri.parse('$backendUrl/api/v1/drivers'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'email': email, 'name': name}),
    );
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 201) {
      throw Exception(body['error'] ?? 'No se pudo invitar al conductor');
    }
    return (body['tempPassword'] as String?) ?? '';
  }

  // ---------------- Asignación conductor <-> vehículo ----------------

  /// Vehículos asignados a un conductor (vía driver_vehicles).
  Future<List<Map<String, dynamic>>> vehiclesForDriver(String userId) async {
    final data = await _c
        .from('driver_vehicles')
        .select('vehicle_id, vehicles:vehicle_id(id, license_plate, model)')
        .eq('user_id', userId);
    return (data as List)
        .map((r) => (r['vehicles'] as Map?)?.cast<String, dynamic>())
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  /// Conductores asignados a un vehículo.
  Future<List<Map<String, dynamic>>> driversForVehicle(String vehicleId) async {
    final data = await _c
        .from('driver_vehicles')
        .select('user_id, users:user_id(id, name, email)')
        .eq('vehicle_id', vehicleId);
    return (data as List)
        .map((r) => (r['users'] as Map?)?.cast<String, dynamic>())
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  /// Reemplaza el conjunto de vehículos de un conductor (solo Owner por RLS).
  Future<void> setVehiclesForDriver({
    required String userId,
    required String tenantId,
    required List<String> vehicleIds,
  }) async {
    await _c.from('driver_vehicles').delete().eq('user_id', userId);
    if (vehicleIds.isEmpty) return;
    await _c.from('driver_vehicles').insert([
      for (final vid in vehicleIds)
        {'tenant_id': tenantId, 'user_id': userId, 'vehicle_id': vid},
    ]);
  }

  /// Reemplaza el conjunto de conductores de un vehículo (solo Owner por RLS).
  Future<void> setDriversForVehicle({
    required String vehicleId,
    required String tenantId,
    required List<String> userIds,
  }) async {
    await _c.from('driver_vehicles').delete().eq('vehicle_id', vehicleId);
    if (userIds.isEmpty) return;
    await _c.from('driver_vehicles').insert([
      for (final uid in userIds)
        {'tenant_id': tenantId, 'user_id': uid, 'vehicle_id': vehicleId},
    ]);
  }

  /// Vehículos del conductor autenticado (para registrar / elegir al empezar).
  Future<List<Map<String, dynamic>>> myVehicles() async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) return [];
    return vehiclesForDriver(uid);
  }

  // ---------------- Transacciones ----------------
  Future<void> addTransaction({
    required String tenantId,
    required String userId,
    required double amount,
    String? category,
    required String type,
    String? paymentMethod,
    String? description,
    String? origin,
    String? destination,
    int? odometerKm,
    String? clientName,
    DateTime? createdAt,
    String? vehicleId,
  }) async {
    final row = <String, dynamic>{
      'tenant_id': tenantId,
      'user_id': userId,
      'vehicle_id': vehicleId,
      'amount': amount,
      'category': category,
      'type': type,
      'payment_method': paymentMethod,
      'description': description,
      'origin': origin,
      'destination': destination,
      'odometer_km': odometerKm,
      'client_name': clientName,
    };
    // Si no se indica, la BD pone now() por defecto.
    if (createdAt != null) row['created_at'] = createdAt.toUtc().toIso8601String();
    await _c.from('transactions').insert(row);
  }

  /// Lista transacciones (RLS: el driver ve las suyas; el owner las de su
  /// tenant). Filtros opcionales combinables y paginación con `.range()`.
  Future<List<Map<String, dynamic>>> listTransactions({
    String? userId,
    String? vehicleId,
    DateTime? from,
    DateTime? to,
    int offset = 0,
    int limit = 20,
  }) async {
    var query = _c.from('transactions').select(
        '*, users:user_id(name, email), vehicles:vehicle_id(license_plate, model)');
    if (userId != null) query = query.eq('user_id', userId);
    if (vehicleId != null) query = query.eq('vehicle_id', vehicleId);
    if (from != null) query = query.gte('created_at', from.toIso8601String());
    if (to != null) query = query.lt('created_at', to.toIso8601String());
    final data = await query
        .order('created_at', ascending: false)
        .range(offset, offset + limit - 1);
    return (data as List).cast<Map<String, dynamic>>();
  }

  /// Una transacción con sus relaciones (conductor + vehículo) para el detalle.
  Future<Map<String, dynamic>?> getTransaction(String id) async {
    final row = await _c
        .from('transactions')
        .select(
            '*, users:user_id(name, email), vehicles:vehicle_id(license_plate, model)')
        .eq('id', id)
        .maybeSingle();
    return row;
  }

  /// Calcula KPIs (ingresos, gastos, balance, gasto por categoría) sobre el
  /// conjunto filtrado completo (no paginado). La RLS limita el alcance.
  Future<TxSummary> transactionsSummary({
    String? userId,
    String? vehicleId,
    DateTime? from,
    DateTime? to,
  }) async {
    var query = _c.from('transactions').select('amount, type, category');
    if (userId != null) query = query.eq('user_id', userId);
    if (vehicleId != null) query = query.eq('vehicle_id', vehicleId);
    if (from != null) query = query.gte('created_at', from.toIso8601String());
    if (to != null) query = query.lt('created_at', to.toIso8601String());
    final rows = (await query as List).cast<Map<String, dynamic>>();

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
    return TxSummary(income: income, expense: expense, expenseByCategory: byCat);
  }

  /// Actualiza una transacción (RLS: owner cualquiera de su tenant; driver las
  /// suyas). Devuelve la fila actualizada o lanza si RLS lo deniega.
  Future<void> updateTransaction(
    String id, {
    required double amount,
    String? category,
    required String type,
    String? paymentMethod,
    String? description,
    String? origin,
    String? destination,
    int? odometerKm,
    String? clientName,
    DateTime? createdAt,
    String? vehicleId,
    bool setVehicle = false,
  }) async {
    final patch = <String, dynamic>{
      'amount': amount,
      'category': category,
      'type': type,
      'payment_method': paymentMethod,
      'description': description,
      'origin': origin,
      'destination': destination,
      'odometer_km': odometerKm,
      'client_name': clientName,
    };
    if (setVehicle) patch['vehicle_id'] = vehicleId;
    if (createdAt != null) patch['created_at'] = createdAt.toUtc().toIso8601String();
    final updated = await _c
        .from('transactions')
        .update(patch)
        .eq('id', id)
        .select();
    if ((updated as List).isEmpty) {
      throw Exception('No tienes permiso para editar esta transacción');
    }
  }

  /// Elimina una transacción (RLS controla el permiso).
  Future<void> deleteTransaction(String id) async {
    final deleted =
        await _c.from('transactions').delete().eq('id', id).select();
    if ((deleted as List).isEmpty) {
      throw Exception('No tienes permiso para eliminar esta transacción');
    }
  }

  /// Envía audio (o texto mock en dev) al backend y devuelve
  /// { text, confidence, parsed: {...} }.
  Future<Map<String, dynamic>> transcribe({
    List<int>? audioBytes,
    String? filename,
    String? mockText,
  }) async {
    final token = _c.auth.currentSession?.accessToken;
    if (token == null) throw Exception('No hay sesión activa');

    http.Response res;
    if (mockText != null) {
      res = await http.post(
        Uri.parse('$backendUrl/api/v1/transcribe'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({'mock_text': mockText}),
      );
    } else {
      final req = http.MultipartRequest('POST', Uri.parse('$backendUrl/api/v1/transcribe'))
        ..headers['Authorization'] = 'Bearer $token'
        ..files.add(http.MultipartFile.fromBytes('audio', audioBytes ?? const [],
            filename: filename ?? 'audio.m4a'));
      final streamed = await req.send();
      res = await http.Response.fromStream(streamed);
    }

    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode == 429) {
      throw Exception('Límite diario de transcripciones alcanzado');
    }
    if (res.statusCode != 200) {
      throw Exception(body['error'] ?? 'Error de transcripción (${res.statusCode})');
    }
    return body;
  }

  // ---------------- Facturación / Suscripción (Fase 4) ----------------

  /// Datos de suscripción del tenant (RLS: cualquier miembro lee su tenant).
  Future<Map<String, dynamic>?> fetchTenantBilling(String tenantId) async {
    return _c
        .from('tenants')
        .select(
            'id, name, subscription_status, plan_id, drivers_limit, stripe_customer_id, stripe_subscription_id')
        .eq('id', tenantId)
        .maybeSingle();
  }

  /// Crea una sesión de Stripe Checkout y devuelve su URL.
  Future<String> createCheckoutSession(String priceId) =>
      _postBilling('/api/v1/create-checkout-session', {'priceId': priceId});

  /// Crea una sesión del Customer Portal de Stripe y devuelve su URL.
  Future<String> createPortalSession() => _postBilling('/api/v1/create-portal-session', {});

  Future<String> _postBilling(String path, Map<String, dynamic> body) async {
    final token = _c.auth.currentSession?.accessToken;
    if (token == null) throw Exception('No hay sesión activa');
    final res = await http.post(
      Uri.parse('$backendUrl$path'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    final decoded = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw Exception(decoded['error'] ?? 'Error de facturación (${res.statusCode})');
    }
    return decoded['url'] as String;
  }

  // ---------------- Informes (Fase 5) ----------------

  /// Descarga un informe ('excel' | 'pdf') con los filtros del dashboard.
  /// Devuelve los bytes del fichero.
  Future<List<int>> downloadReport({
    required String format,
    DateTime? from,
    DateTime? to,
    String? driverId,
    String? vehicleId,
  }) async {
    final token = _c.auth.currentSession?.accessToken;
    if (token == null) throw Exception('No hay sesión activa');
    final res = await http.post(
      Uri.parse('$backendUrl/api/v1/reports/$format'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: jsonEncode({
        'startDate': from?.toIso8601String(),
        'endDate': to?.toIso8601String(),
        'driverId': driverId,
        'vehicleId': vehicleId,
      }),
    );
    if (res.statusCode == 504) {
      throw Exception('La exportación ha tardado demasiado. Prueba con un rango de fechas más pequeño.');
    }
    if (res.statusCode != 200) {
      String msg = 'Error al generar el informe (${res.statusCode})';
      try {
        msg = (jsonDecode(res.body) as Map<String, dynamic>)['error'] as String? ?? msg;
      } catch (_) {}
      throw Exception(msg);
    }
    return res.bodyBytes;
  }

  // ---------------- Onboarding ----------------
  Future<void> completeOnboarding() async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) return;
    await _c.from('users').update({'has_completed_onboarding': true}).eq('id', uid);
  }
}
