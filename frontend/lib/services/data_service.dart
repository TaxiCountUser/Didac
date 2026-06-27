import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../models/profile.dart';
import '../models/tenant_state.dart';

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

  /// Marca el tutorial de bienvenida como visto (para que no vuelva a salir).
  Future<void> markTutorialSeen() async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) return;
    await _c.from('users').update({'tutorial_seen': true}).eq('id', uid);
  }

  // ---------------- Alta diferida (elegir flota) ----------------

  /// Crea la empresa del usuario pendiente y lo convierte en propietario.
  Future<void> createOwnerCompany(String name) async {
    await _c.rpc('create_owner_company', params: {'p_name': name});
  }

  /// Crea la empresa en modo autónomo (el usuario es empresa y chófer a la vez).
  Future<void> createSoloCompany(String name) async {
    await _c.rpc('create_solo_company', params: {'p_name': name});
  }

  // ---------------- Referidos ----------------

  /// Aplica el código de quien me invitó (una sola vez).
  Future<void> setMyReferrer(String code) async {
    await _c.rpc('set_my_referrer', params: {'p_code': code});
  }

  /// Estadísticas de mis referidos: {total, rewarded} (los que ya han pagado).
  Future<Map<String, int>> myReferralStats() async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) return {'total': 0, 'rewarded': 0};
    final rows = await _c.from('referrals').select('status').eq('referrer_user_id', uid);
    final list = (rows as List).cast<Map<String, dynamic>>();
    final rewarded = list.where((r) => r['status'] == 'rewarded').length;
    return {'total': list.length, 'rewarded': rewarded};
  }

  /// Activa/desactiva el modo autónomo (solo) de mi empresa (solo propietario).
  Future<void> setSoloMode(bool solo) async {
    await _c.rpc('set_solo_mode', params: {'p_solo': solo});
  }

  /// Estado de mi empresa (modo autónomo, suscripción y prueba de 15 días).
  Future<TenantState?> fetchMyTenantState(String tenantId) async {
    if (tenantId.isEmpty) return null;
    final row = await _c
        .from('tenants')
        .select('id, name, solo, subscription_status, plan_id, trial_ends_at')
        .eq('id', tenantId)
        .maybeSingle();
    return row == null ? null : TenantState.fromMap(row);
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

  // ---------------- Panel de administrador de plataforma ----------------

  Map<String, String> get _bearer {
    final token = _c.auth.currentSession?.accessToken;
    if (token == null) throw Exception('No hay sesión activa');
    return {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};
  }

  /// Progreso de los retos de todos los conductores de la empresa (solo owner).
  Future<Map<String, dynamic>> companyChallenges() async {
    final res = await http.get(Uri.parse('$backendUrl/api/v1/challenges/company'), headers: _bearer);
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    return body;
  }

  /// Retos logrados pendientes de revisar (solo admin, todas las empresas).
  Future<List<Map<String, dynamic>>> adminChallenges() async {
    final res = await http.get(Uri.parse('$backendUrl/api/v1/admin/challenges'), headers: _bearer);
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    return ((body['claims'] as List?) ?? []).cast<Map<String, dynamic>>();
  }

  /// Aprueba (mes gratis) o rechaza un reto logrado (solo admin).
  Future<void> adminReviewChallenge(String id, String action) async {
    final res = await http.post(
      Uri.parse('$backendUrl/api/v1/admin/challenges/$id'),
      headers: _bearer,
      body: jsonEncode({'action': action}),
    );
    if (res.statusCode != 200) {
      final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'No se pudo procesar el reto');
    }
  }

  /// Resumen de todas las empresas (solo admin).
  Future<Map<String, dynamic>> adminOverview() async {
    final res = await http.get(Uri.parse('$backendUrl/api/v1/admin/overview'), headers: _bearer);
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    return body;
  }

  /// Incidencias de todas las empresas (opcionalmente filtradas por estado).
  Future<List<Map<String, dynamic>>> adminIncidents({String? status}) async {
    final qp = (status == null || status.isEmpty) ? '' : '?status=$status';
    final res = await http.get(Uri.parse('$backendUrl/api/v1/admin/incidents$qp'), headers: _bearer);
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    return ((body['incidents'] as List?) ?? []).cast<Map<String, dynamic>>();
  }

  /// Mensajes del chat de una incidencia (solo admin, cualquier empresa).
  Future<List<Map<String, dynamic>>> adminIncidentMessages(String id) async {
    final res = await http.get(
        Uri.parse('$backendUrl/api/v1/admin/incidents/$id/messages'), headers: _bearer);
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    return ((body['messages'] as List?) ?? []).cast<Map<String, dynamic>>();
  }

  /// Envía un mensaje en el chat de una incidencia (solo admin).
  Future<void> adminSendIncidentMessage(String id, String text) async {
    final res = await http.post(
      Uri.parse('$backendUrl/api/v1/admin/incidents/$id/messages'),
      headers: _bearer,
      body: jsonEncode({'body': text}),
    );
    if (res.statusCode != 200) {
      final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'No se pudo enviar el mensaje');
    }
  }

  /// Resolver / reabrir una incidencia de cualquier empresa (solo admin).
  Future<void> adminSetIncidentStatus(String id, String status) async {
    final res = await http.post(
      Uri.parse('$backendUrl/api/v1/admin/incidents/$id/status'),
      headers: _bearer,
      body: jsonEncode({'status': status}),
    );
    if (res.statusCode != 200) {
      final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'No se pudo actualizar la incidencia');
    }
  }

  /// Lista de administradores actuales (solo admin).
  Future<List<Map<String, dynamic>>> adminListAdmins() async {
    final res = await http.get(Uri.parse('$backendUrl/api/v1/admin/admins'), headers: _bearer);
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    return ((body['admins'] as List?) ?? []).cast<Map<String, dynamic>>();
  }

  /// Nombrar (o quitar) admin a otro usuario por correo (solo admin).
  Future<void> adminMakeAdmin(String email, {bool isAdmin = true}) async {
    final res = await http.post(
      Uri.parse('$backendUrl/api/v1/admin/make-admin'),
      headers: _bearer,
      body: jsonEncode({'email': email, 'isAdmin': isAdmin}),
    );
    if (res.statusCode != 200) {
      final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'No se pudo cambiar el rol de admin');
    }
  }

  /// Detalle completo de una empresa (tenant + usuarios + recuentos).
  Future<Map<String, dynamic>> adminCompany(String id) async {
    final res = await http.get(Uri.parse('$backendUrl/api/v1/admin/company/$id'), headers: _bearer);
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    return body;
  }

  /// Modificar una empresa (suscripción, plan, límite, prueba, nombre, solo).
  Future<void> adminUpdateCompany(String id, Map<String, dynamic> patch) async {
    final res = await http.patch(
      Uri.parse('$backendUrl/api/v1/admin/company/$id'),
      headers: _bearer,
      body: jsonEncode(patch),
    );
    if (res.statusCode != 200) {
      final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'No se pudo actualizar la empresa');
    }
  }

  /// Eliminar una empresa entera (cascada) y las cuentas de sus usuarios.
  Future<void> adminDeleteCompany(String id) async {
    final res = await http.delete(
      Uri.parse('$backendUrl/api/v1/admin/company/$id'),
      headers: _bearer,
    );
    if (res.statusCode != 200) {
      final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'No se pudo eliminar la empresa');
    }
  }

  /// Modificar un usuario de cualquier empresa (activar, rol, nombre, admin).
  Future<void> adminUpdateUser(String id, Map<String, dynamic> patch) async {
    final res = await http.patch(
      Uri.parse('$backendUrl/api/v1/admin/user/$id'),
      headers: _bearer,
      body: jsonEncode(patch),
    );
    if (res.statusCode != 200) {
      final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'No se pudo actualizar el usuario');
    }
  }

  /// Vehículos asignados a un conductor (admin): lista de ids.
  Future<List<String>> adminUserVehicles(String userId) async {
    final res = await http.get(
        Uri.parse('$backendUrl/api/v1/admin/user/$userId/vehicles'), headers: _bearer);
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    return ((body['vehicleIds'] as List?) ?? []).cast<String>();
  }

  /// Asigna qué vehículos usa un conductor (admin). Reemplaza el conjunto.
  Future<void> adminSetUserVehicles(String userId, List<String> vehicleIds) async {
    final res = await http.post(
      Uri.parse('$backendUrl/api/v1/admin/user/$userId/vehicles'),
      headers: _bearer,
      body: jsonEncode({'vehicleIds': vehicleIds}),
    );
    if (res.statusCode != 200) {
      final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'No se pudieron asignar los vehículos');
    }
  }

  /// Eliminar un usuario (perfil + cuenta de auth).
  Future<void> adminDeleteUser(String id) async {
    final res = await http.delete(
      Uri.parse('$backendUrl/api/v1/admin/user/$id'),
      headers: _bearer,
    );
    if (res.statusCode != 200) {
      final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'No se pudo eliminar el usuario');
    }
  }

  /// Añadir un vehículo a una empresa (admin).
  Future<void> adminAddVehicle(String tenantId, String plate, String? model) async {
    final res = await http.post(
      Uri.parse('$backendUrl/api/v1/admin/company/$tenantId/vehicle'),
      headers: _bearer,
      body: jsonEncode({'license_plate': plate, 'model': model}),
    );
    if (res.statusCode != 200) {
      final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'No se pudo añadir el vehículo');
    }
  }

  /// Editar un vehículo (admin).
  Future<void> adminUpdateVehicle(String id, {String? plate, String? model}) async {
    final res = await http.patch(
      Uri.parse('$backendUrl/api/v1/admin/vehicle/$id'),
      headers: _bearer,
      body: jsonEncode({
        if (plate != null) 'license_plate': plate,
        if (model != null) 'model': model,
      }),
    );
    if (res.statusCode != 200) {
      final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'No se pudo editar el vehículo');
    }
  }

  /// Eliminar un vehículo (admin).
  Future<void> adminDeleteVehicle(String id) async {
    final res = await http.delete(
      Uri.parse('$backendUrl/api/v1/admin/vehicle/$id'),
      headers: _bearer,
    );
    if (res.statusCode != 200) {
      final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'No se pudo eliminar el vehículo');
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
  /// Si el usuario es PROPIETARIO (incluido el autónomo, que es su propio
  /// chófer), puede conducir CUALQUIER vehículo de su empresa, así que devolvemos
  /// todos. Un conductor normal ve solo los que tiene asignados.
  Future<List<Map<String, dynamic>>> myVehicles() async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) return [];
    final me = await _c.from('users').select('role').eq('id', uid).maybeSingle();
    if (me?['role'] == 'owner') {
      // Si se ha asignado vehículos a sí mismo, usa esos (puede elegir cuáles);
      // si no, todos los de la empresa (para que funcione sin configurar nada).
      final assigned = await vehiclesForDriver(uid);
      if (assigned.isNotEmpty) return assigned;
      return listVehicles();
    }
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
            'id, name, subscription_status, plan_id, drivers_limit, stripe_customer_id, stripe_subscription_id, solo, trial_ends_at')
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
    List<String>? clients,
    List<String>? excludeClients,
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
        if (clients != null && clients.isNotEmpty) 'clients': clients,
        if (excludeClients != null && excludeClients.isNotEmpty) 'excludeClients': excludeClients,
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

  /// Transacciones ligeras para estadísticas/comparativas (amount, type, fecha).
  /// RLS: el owner ve las de su tenant. Filtros opcionales por conductor/coche/rango.
  Future<List<Map<String, dynamic>>> statsTransactions({
    String? driverId,
    String? vehicleId,
    DateTime? from,
    DateTime? to,
  }) async {
    var q = _c.from('transactions').select('amount, type, created_at');
    if (driverId != null) q = q.eq('user_id', driverId);
    if (vehicleId != null) q = q.eq('vehicle_id', vehicleId);
    if (from != null) q = q.gte('created_at', from.toIso8601String());
    if (to != null) q = q.lt('created_at', to.toIso8601String());
    final data = await q.order('created_at').limit(10000);
    return (data as List).cast<Map<String, dynamic>>();
  }

  /// Empresas/clientes distintos que aparecen en las transacciones (para filtrar
  /// la exportación). Ordenados alfabéticamente.
  Future<List<String>> distinctClients() async {
    final data = await _c
        .from('transactions')
        .select('client_name')
        .not('client_name', 'is', null)
        .limit(5000);
    final set = <String>{};
    for (final r in (data as List)) {
      final c = (r['client_name'] as String?)?.trim();
      if (c != null && c.isNotEmpty) set.add(c);
    }
    final list = set.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  /// Importa un Excel/CSV antiguo. [type]: 'auto' | 'income' | 'expense' (tipo
  /// por defecto si el fichero no trae columna de tipo). Devuelve {imported, skipped}.
  Future<Map<String, dynamic>> importTransactions({
    required List<int> bytes,
    required String filename,
    String type = 'auto',
    bool preview = false,
  }) async {
    final token = _c.auth.currentSession?.accessToken;
    if (token == null) throw Exception('No hay sesión activa');
    final uri = Uri.parse('$backendUrl/api/v1/import/transactions?type=$type${preview ? '&preview=true' : ''}');
    final req = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $token'
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final res = await http.Response.fromStream(await req.send());
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw Exception(body['error'] ?? 'No se pudo importar (${res.statusCode})');
    }
    return body;
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

  /// Incidencias visibles para el usuario en su panel: las notas (conductor<->
  /// jefe) y, además, los reportes de fallo ('app') que ÉL mismo creó, para que
  /// pueda seguir el chat con la administración. (RLS sigue acotando por tenant.)
  Future<List<Map<String, dynamic>>> listVisibleIncidents() async {
    final uid = _c.auth.currentUser?.id;
    var q = _c.from('incidents').select('*, users:user_id(name, email)');
    if (uid != null) q = q.or('kind.eq.nota,user_id.eq.$uid');
    final data = await q.order('created_at', ascending: false);
    return (data as List).cast<Map<String, dynamic>>();
  }

  /// Mis tickets de soporte (reportes de fallo 'app' que yo he creado), abiertos
  /// y cerrados, para chatear con la administración.
  Future<List<Map<String, dynamic>>> listMyTickets() async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) return [];
    final data = await _c
        .from('incidents')
        .select('*, users:user_id(name, email)')
        .eq('kind', 'app')
        .eq('user_id', uid)
        .order('created_at', ascending: false);
    return (data as List).cast<Map<String, dynamic>>();
  }

  /// Fecha del último mensaje de OTRA persona (admin) en mis tickets, o null si
  /// no hay respuestas. Sirve para avisar "el admin te ha contestado".
  Future<DateTime?> latestTicketReplyAt() async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) return null;
    final tickets = await _c.from('incidents').select('id').eq('kind', 'app').eq('user_id', uid);
    final ids = (tickets as List).map((r) => r['id'] as String).toList();
    if (ids.isEmpty) return null;
    final msgs = await _c
        .from('incident_messages')
        .select('created_at')
        .inFilter('incident_id', ids)
        .neq('user_id', uid)
        .order('created_at', ascending: false)
        .limit(1);
    final list = msgs as List;
    if (list.isEmpty) return null;
    return DateTime.tryParse(list.first['created_at'] as String);
  }

  /// Crea un ticket de soporte ('app') y devuelve la fila (para abrir el chat).
  Future<Map<String, dynamic>?> createTicket(String tenantId, String body) async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) throw Exception('No hay sesión activa');
    final rows = await _c.from('incidents').insert({
      'tenant_id': tenantId,
      'user_id': uid,
      'kind': 'app',
      'body': body,
    }).select('id, kind, body, status, created_at');
    final row = (rows as List).isNotEmpty ? (rows.first as Map).cast<String, dynamic>() : null;
    if (row != null) {
      await _notifyIncident(incidentId: row['id'] as String, kind: 'new_incident', body: body);
    }
    return row;
  }

  /// Mensajes de chat de una incidencia (con autor), orden cronológico.
  Future<List<Map<String, dynamic>>> listIncidentMessages(String incidentId) async {
    final data = await _c
        .from('incident_messages')
        .select('*, users:user_id(name, email, role, is_admin)')
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

  /// Nº de incidencias abiertas (para el badge del panel del jefe). Solo 'nota'
  /// (los reportes de fallo 'app' van al panel de administración).
  Future<int> openIncidentsCount() async {
    final data = await _c
        .from('incidents')
        .select('id')
        .eq('status', 'abierta')
        .eq('kind', 'nota');
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

  /// Oculta una incidencia del panel de la empresa (soft-delete). NO la borra:
  /// el admin de plataforma la sigue viendo por si hay un problema a futuro.
  Future<void> hideIncident(String id) async {
    final updated = await _c
        .from('incidents')
        .update({'hidden_for_tenant': true}).eq('id', id).select();
    if ((updated as List).isEmpty) {
      throw Exception('No se pudo ocultar la incidencia');
    }
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
