import 'dart:async';
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

  // ---------------- Alta diferida (elegir flota) ----------------

  /// Crea la empresa del usuario pendiente y lo convierte en propietario.
  Future<void> createOwnerCompany(String name) async {
    await _c.rpc('create_owner_company', params: {'p_name': name});
  }

  /// Une al usuario pendiente a una flota usando el código del jefe.
  /// Devuelve el nombre de la flota a la que se ha unido.
  Future<String> joinFleetWithCode(String code) async {
    final res = await _c.rpc('join_fleet_with_code', params: {'p_code': code});
    final map = (res as Map?)?.cast<String, dynamic>();
    return (map?['name'] as String?) ?? '';
  }

  /// Código para que los trabajadores se unan a esta flota (solo Owner).
  Future<String?> myFleetCode(String tenantId) async {
    if (tenantId.isEmpty) return null;
    final row = await _c.from('tenants').select('join_code').eq('id', tenantId).maybeSingle();
    return row?['join_code'] as String?;
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

  /// Actualiza la ficha de mantenimiento de un vehículo (solo Owner por RLS).
  /// Solo escribe las claves presentes en [fields]; usa null para borrar un dato.
  Future<void> updateVehicleMaintenance(String id, Map<String, dynamic> fields) async {
    if (fields.isEmpty) return;
    await _c.from('vehicles').update(fields).eq('id', id);
  }

  /// Km actuales (máx. conocido) de varios vehículos a la vez, para la lista.
  /// Devuelve {vehicleId: km} solo con los que tienen alguna lectura.
  Future<Map<String, int>> currentKmFor(List<String> vehicleIds) async {
    final out = <String, int>{};
    for (final id in vehicleIds) {
      final km = await lastOdometer(id);
      if (km != null) out[id] = km;
    }
    return out;
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

  /// Edita un conductor desde el panel del Owner (vía backend service_role).
  /// Pasa solo los campos que quieras cambiar; [username]/[name] '' borran el dato.
  /// [active]=false lo saca de la flota; true lo reincorpora.
  Future<void> updateDriver({
    required String id,
    String? username,
    String? password,
    String? name,
    bool? active,
  }) async {
    final token = _c.auth.currentSession?.accessToken;
    if (token == null) throw Exception('No hay sesión activa');
    final res = await http.patch(
      Uri.parse('$backendUrl/api/v1/drivers/$id'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        if (username != null) 'username': username,
        if (password != null && password.isNotEmpty) 'password': password,
        if (name != null) 'name': name,
        if (active != null) 'active': active,
      }),
    );
    if (res.statusCode != 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'No se pudo actualizar el conductor');
    }
  }

  /// Elimina definitivamente la cuenta de un conductor (vía backend).
  Future<void> deleteDriver(String id) async {
    final token = _c.auth.currentSession?.accessToken;
    if (token == null) throw Exception('No hay sesión activa');
    final res = await http.delete(
      Uri.parse('$backendUrl/api/v1/drivers/$id'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode != 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'No se pudo eliminar el conductor');
    }
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

  /// El Owner edita el nombre de un conductor de su flota (RPC con permisos).
  Future<void> ownerSetDriverName(String driverId, String name) async {
    await _c.rpc('owner_set_driver_name', params: {'p_driver': driverId, 'p_name': name});
  }

  /// Vehículos del conductor autenticado (para registrar / elegir al empezar).
  Future<List<Map<String, dynamic>>> myVehicles() async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) return [];
    return vehiclesForDriver(uid);
  }

  // ---------------- Km diarios (odómetro) ----------------

  /// Últimos km conocidos de un vehículo (máx. entre lecturas y transacciones).
  Future<int?> lastOdometer(String vehicleId) async {
    int? best;
    final r = await _c
        .from('odometer_readings')
        .select('reading_km')
        .eq('vehicle_id', vehicleId)
        .order('reading_km', ascending: false)
        .limit(1);
    if ((r as List).isNotEmpty) best = (r.first['reading_km'] as num).toInt();
    final t = await _c
        .from('transactions')
        .select('odometer_km')
        .eq('vehicle_id', vehicleId)
        .not('odometer_km', 'is', null)
        .order('odometer_km', ascending: false)
        .limit(1);
    if ((t as List).isNotEmpty && t.first['odometer_km'] != null) {
      final k = (t.first['odometer_km'] as num).toInt();
      if (best == null || k > best) best = k;
    }
    return best;
  }

  /// ¿Hay ya una lectura de hoy para este vehículo y conductor?
  Future<bool> hasOdometerToday(String vehicleId, String userId) async {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final rows = await _c
        .from('odometer_readings')
        .select('id')
        .eq('vehicle_id', vehicleId)
        .eq('user_id', userId)
        .gte('taken_at', startOfDay.toUtc().toIso8601String())
        .limit(1);
    return (rows as List).isNotEmpty;
  }

  /// Vehículo elegido HOY por el conductor (última lectura de hoy), o null.
  /// Sirve como vehículo "activo" del día para preseleccionar en el formulario.
  Future<String?> todaysVehicleId(String userId) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final rows = await _c
        .from('odometer_readings')
        .select('vehicle_id')
        .eq('user_id', userId)
        .gte('taken_at', start.toUtc().toIso8601String())
        .order('taken_at', ascending: false)
        .limit(1);
    return (rows as List).isNotEmpty ? rows.first['vehicle_id'] as String? : null;
  }

  /// Registra una lectura de km.
  Future<void> addOdometerReading({
    required String tenantId,
    required String vehicleId,
    required String userId,
    required int readingKm,
  }) async {
    await _c.from('odometer_readings').insert({
      'tenant_id': tenantId,
      'vehicle_id': vehicleId,
      'user_id': userId,
      'reading_km': readingKm,
    });
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
    String? client,
    String? search,
    int offset = 0,
    int limit = 20,
  }) async {
    var query = _c.from('transactions').select(
        '*, users:user_id(name, email), vehicles:vehicle_id(license_plate, model)');
    if (userId != null) query = query.eq('user_id', userId);
    if (vehicleId != null) query = query.eq('vehicle_id', vehicleId);
    if (from != null) query = query.gte('created_at', from.toIso8601String());
    if (to != null) query = query.lt('created_at', to.toIso8601String());
    if (client != null && client.isNotEmpty) {
      query = query.ilike('client_name', '%$client%');
    }
    // Buscador libre: empresa (client_name), origen, destino o descripción.
    if (search != null && search.trim().isNotEmpty) {
      final s = search.trim().replaceAll(',', ' ').replaceAll('%', '');
      query = query.or(
          'client_name.ilike.%$s%,description.ilike.%$s%,origin.ilike.%$s%,destination.ilike.%$s%');
    }
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
    String? client,
  }) async {
    var query = _c.from('transactions').select('amount, type, category');
    if (userId != null) query = query.eq('user_id', userId);
    if (vehicleId != null) query = query.eq('vehicle_id', vehicleId);
    if (from != null) query = query.gte('created_at', from.toIso8601String());
    if (to != null) query = query.lt('created_at', to.toIso8601String());
    if (client != null && client.isNotEmpty) {
      query = query.ilike('client_name', '%$client%');
    }
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
    String? language, // pista de idioma para Whisper (es/ca/en)
  }) async {
    final token = _c.auth.currentSession?.accessToken;
    if (token == null) throw Exception('No hay sesión activa');

    final qp = (language != null && language.isNotEmpty) ? '?language=$language' : '';
    final uri = Uri.parse('$backendUrl/api/v1/transcribe$qp');

    http.Response res;
    if (mockText != null) {
      res = await http.post(
        uri,
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({'mock_text': mockText}),
      );
    } else {
      final req = http.MultipartRequest('POST', uri)
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

  /// Actualiza el nombre de la empresa (solo Owner, solo columna name por RLS).
  Future<void> updateCompanyName(String tenantId, String name) async {
    await _c.from('tenants').update({'name': name}).eq('id', tenantId);
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
    String? client,
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
        'client': client,
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

  // ---------------- Incidencias / notas al jefe ----------------

  /// Lista incidencias (RLS: owner las de su tenant; conductor las suyas).
  /// Incluye el autor para que el Owner sepa quién la escribió.
  Future<List<Map<String, dynamic>>> listIncidents({String? kind}) async {
    var q = _c.from('incidents').select('*, users:user_id(name, email)');
    if (kind != null) q = q.eq('kind', kind);
    final data = await q.order('created_at', ascending: false);
    return (data as List).cast<Map<String, dynamic>>();
  }

  /// Mensajes de chat de una incidencia (con autor), orden cronológico.
  Future<List<Map<String, dynamic>>> listIncidentMessages(String incidentId) async {
    final data = await _c
        .from('incident_messages')
        .select('*, users:user_id(name, email)')
        .eq('incident_id', incidentId)
        .order('created_at');
    return (data as List).cast<Map<String, dynamic>>();
  }

  /// Envía un mensaje en el chat de una incidencia (RLS: owner o autor, y solo
  /// si la incidencia no está resuelta).
  Future<void> addIncidentMessage({
    required String incidentId,
    required String tenantId,
    required String body,
  }) async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) throw Exception('No hay sesión activa');
    await _c.from('incident_messages').insert({
      'incident_id': incidentId,
      'tenant_id': tenantId,
      'user_id': uid,
      'body': body,
    });
    await _notifyIncident(incidentId: incidentId, kind: 'new_message', body: body);
  }

  /// Pide al backend que envíe el push de una incidencia/mensaje. Best-effort:
  /// si push no está configurado o falla, no pasa nada (la app sigue igual).
  Future<void> _notifyIncident({
    required String incidentId,
    required String kind,
    String? body,
  }) async {
    try {
      final token = _c.auth.currentSession?.accessToken;
      if (token == null) return;
      await http
          .post(
            Uri.parse('$backendUrl/api/v1/notify-incident'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'incidentId': incidentId,
              'kind': kind,
              if (body != null) 'body': body,
            }),
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {/* best-effort */}
  }

  /// Nº de incidencias abiertas (para el badge del panel del jefe).
  Future<int> openIncidentsCount() async {
    final data = await _c.from('incidents').select('id').eq('status', 'abierta');
    return (data as List).length;
  }

  /// Crea una incidencia: kind 'nota' (mensaje al jefe) o 'app' (fallo de la app).
  Future<void> addIncident({
    required String tenantId,
    required String kind,
    required String body,
  }) async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) throw Exception('No hay sesión activa');
    final rows = await _c.from('incidents').insert({
      'tenant_id': tenantId,
      'user_id': uid,
      'kind': kind,
      'body': body,
    }).select('id');
    final id = (rows as List).isNotEmpty ? rows.first['id'] as String? : null;
    if (id != null) {
      await _notifyIncident(incidentId: id, kind: 'new_incident', body: body);
    }
  }

  /// Elimina una incidencia (solo Owner por RLS).
  Future<void> deleteIncident(String id) async {
    await _c.from('incidents').delete().eq('id', id);
  }

  /// Autolimpieza: borra las incidencias de más de 90 días del tenant. Devuelve
  /// cuántas borró. Best-effort (se llama al abrir el panel del jefe).
  Future<int> cleanupOldIncidents() async {
    final n = await _c.rpc('cleanup_old_incidents');
    return (n is int) ? n : 0;
  }

  /// Marca una incidencia como resuelta (solo Owner por RLS).
  Future<void> resolveIncident(String id) async {
    final updated =
        await _c.from('incidents').update({'status': 'resuelta'}).eq('id', id).select();
    if ((updated as List).isEmpty) {
      throw Exception('No se pudo actualizar la incidencia');
    }
  }

  // ---------------- Ubicación (localizar vehículo) ----------------

  /// Guarda/actualiza la última ubicación del conductor autenticado (upsert).
  Future<void> updateMyLocation({
    required String tenantId,
    required double lat,
    required double lng,
    double? accuracy,
  }) async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) return;
    await _c.from('driver_locations').upsert({
      'user_id': uid,
      'tenant_id': tenantId,
      'lat': lat,
      'lng': lng,
      'accuracy': accuracy,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Últimas ubicaciones de los conductores (RLS: el owner ve las de su tenant).
  Future<List<Map<String, dynamic>>> listDriverLocations() async {
    final data = await _c
        .from('driver_locations')
        .select('*, users:user_id(name, email)')
        .order('updated_at', ascending: false);
    return (data as List).cast<Map<String, dynamic>>();
  }

  // ---------------- Perfil ----------------

  /// Actualiza el nombre "de avatar" del propio usuario (RLS: users_update_self).
  /// No cambia el `name` que ve el jefe.
  Future<void> updateDisplayName(String? displayName) async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) return;
    await _c.from('users').update({
      'display_name': (displayName == null || displayName.trim().isEmpty) ? null : displayName.trim(),
    }).eq('id', uid);
  }

  /// Traduce un nombre de usuario a su correo (para iniciar sesión con usuario).
  Future<String?> emailForUsername(String username) async {
    final res = await _c.rpc('email_for_username', params: {'p_username': username});
    return res as String?;
  }

  /// Define el nombre de usuario del propio usuario (único; null para quitarlo).
  Future<void> updateUsername(String? username) async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) return;
    await _c.from('users').update({
      'username': (username == null || username.trim().isEmpty) ? null : username.trim(),
    }).eq('id', uid);
  }

  /// Actualiza el avatar (foto base64 o null = icono) del propio usuario.
  Future<void> updateAvatar(String? avatarBase64) async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) return;
    await _c.from('users').update({
      'avatar_url': (avatarBase64 == null || avatarBase64.isEmpty) ? null : avatarBase64,
    }).eq('id', uid);
  }

  /// Actualiza el nº de licencia del propio conductor.
  Future<void> updateLicenseNumber(String? license) async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) return;
    await _c.from('users').update({
      'license_number': (license == null || license.trim().isEmpty) ? null : license.trim(),
    }).eq('id', uid);
  }

  // ---------------- Onboarding ----------------
  Future<void> completeOnboarding() async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) return;
    await _c.from('users').update({'has_completed_onboarding': true}).eq('id', uid);
  }
}
