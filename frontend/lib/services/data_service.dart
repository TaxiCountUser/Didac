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

/// Informe de cierre de jornada (punto 4): km, horas, ingresos por método y €/km.
class DailyReport {
  final DateTime date;
  final double income;
  final double expense;
  final Map<String, double> incomeByMethod; // efectivo/tarjeta/bizum/credito…
  final double? km;        // km fin - km inicio; null si aún no se sabe (sin cierre)
  final double? kmStart;
  final double? kmEnd;
  final double? hours;     // horas trabajadas (primera a última actividad)
  const DailyReport({
    required this.date,
    required this.income,
    required this.expense,
    required this.incomeByMethod,
    this.km,
    this.kmStart,
    this.kmEnd,
    this.hours,
  });
  double get balance => income - expense;
  /// Precio medio por km del día (ingresos / km), o null si no hay km.
  double? get pricePerKm => (km != null && km! > 0) ? income / km! : null;
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

  /// Cambia la contraseña del propio usuario (GoTrue) y limpia la marca de
  /// "contraseña temporal" (M-05). La marca se quita por RPC SECURITY DEFINER
  /// porque la columna no es editable por PATCH directo.
  Future<void> changeMyPassword(String newPassword) async {
    await _c.auth.updateUser(UserAttributes(password: newPassword));
    await _c.rpc('mark_password_changed');
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

  // ---------------- Referidos "Invita y Gana" (v2, por hitos) ----------------
  // Capa de datos del módulo de referidos. Todo va por el backend (service_role
  // + reglas de negocio: elegibilidad, hitos, anti-fraude). Devuelve Map/List
  // como el resto del proyecto (sin modelos json_serializable).

  /// Código del referidor + elegibilidad + definición de hitos.
  /// Respuesta: {enabled, eligible, code, milestones[], annual_max_days, validation_days}.
  Future<Map<String, dynamic>> referralCode() async {
    final res = await http.get(Uri.parse('$backendUrl/api/v1/referrals/code'), headers: _bearer);
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    return body;
  }

  /// Registra una compartición (canal: whatsapp/email/sms/link). Lanza si supera
  /// el límite diario (429) para que la UI muestre el aviso.
  Future<Map<String, dynamic>> referralShare(String channel) async {
    final res = await http.post(
      Uri.parse('$backendUrl/api/v1/referrals/share'),
      headers: _bearer,
      body: jsonEncode({'channel': channel}),
    );
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    }
    return body;
  }

  /// El referido aplica un código (tras crear su empresa). [deviceId] para
  /// anti-fraude. Lanza con el mensaje del backend si el código no es válido.
  Future<void> referralValidate(String code, {String? deviceId}) async {
    final res = await http.post(
      Uri.parse('$backendUrl/api/v1/referrals/validate'),
      headers: _bearer,
      body: jsonEncode({'code': code, if (deviceId != null) 'device_id': deviceId}),
    );
    if (res.statusCode != 200) {
      final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'No se pudo aplicar el código');
    }
  }

  /// Historial de mis referidos (estado y fechas).
  Future<List<Map<String, dynamic>>> referralHistory() async {
    final res = await http.get(Uri.parse('$backendUrl/api/v1/referrals/history'), headers: _bearer);
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    return ((body['referrals'] as List?) ?? []).cast<Map<String, dynamic>>();
  }

  /// Progreso de hitos: {valid_referrals, milestones[], next, annual_days, annual_max}.
  Future<Map<String, dynamic>> referralProgress() async {
    final res = await http.get(Uri.parse('$backendUrl/api/v1/referrals/progress'), headers: _bearer);
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    return body;
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
    int? registeredKm,
  }) async {
    await _c.from('vehicles').insert({
      'tenant_id': tenantId,
      'license_plate': licensePlate,
      'model': model,
      if (registeredKm != null) 'registered_km': registeredKm,
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

  /// Progreso del trimestre EN CURSO de la flota (solo owner/admin).
  /// Devuelve { year, quarter, active_drivers, drivers_with_achievement,
  /// completion_rate, reward_days_projected }.
  Future<Map<String, dynamic>> fleetCurrentQuarter() async {
    final res = await http.get(
      Uri.parse('$backendUrl/api/v1/tenant/current-quarter-progress'), headers: _bearer);
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    return body;
  }

  /// Histórico de recompensas trimestrales de la flota (solo owner/admin).
  Future<List<Map<String, dynamic>>> fleetQuarterlyMetrics({int limit = 12}) async {
    final res = await http.get(
      Uri.parse('$backendUrl/api/v1/tenant/quarterly-metrics?limit=$limit'), headers: _bearer);
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    return ((body['metrics'] as List?) ?? []).cast<Map<String, dynamic>>();
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

  // ── Loop #5: dashboard de super admin (super retos) ────────────────────────

  /// KPIs de super retos (solo admin).
  Future<Map<String, dynamic>> adminChallengeSummary() async {
    final res = await http.get(Uri.parse('$backendUrl/api/v1/admin/challenges/summary'), headers: _bearer);
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    return body;
  }

  /// Detalle ampliado de un reto (historial del conductor + comparativa).
  Future<Map<String, dynamic>> adminChallengeDetail(String id) async {
    final res = await http.get(Uri.parse('$backendUrl/api/v1/admin/challenges/$id'), headers: _bearer);
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    return body;
  }

  /// Forzar finalización de un reto con justificación (solo admin).
  Future<void> adminChallengeForceComplete(String id, String reason) async {
    final res = await http.post(Uri.parse('$backendUrl/api/v1/admin/challenges/$id/force-complete'),
        headers: _bearer, body: jsonEncode({'reason': reason}));
    if (res.statusCode != 200) {
      final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'No se pudo forzar');
    }
  }

  /// Recompensas trimestrales de todas las empresas (solo admin).
  Future<Map<String, dynamic>> adminChallengeQuarterly({int? year, int? quarter, int limit = 50, int offset = 0}) async {
    final qp = <String, String>{'limit': '$limit', 'offset': '$offset'};
    if (year != null) qp['year'] = '$year';
    if (quarter != null) qp['quarter'] = '$quarter';
    final uri = Uri.parse('$backendUrl/api/v1/admin/challenges/quarterly').replace(queryParameters: qp);
    final res = await http.get(uri, headers: _bearer);
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    return body;
  }

  /// Ajustar manualmente una recompensa trimestral (solo admin).
  Future<void> adminChallengeQuarterlyAdjust(String id, int rewardDays, String reason) async {
    final res = await http.put(Uri.parse('$backendUrl/api/v1/admin/challenges/quarterly/$id'),
        headers: _bearer, body: jsonEncode({'reward_days_awarded': rewardDays, 'reason': reason}));
    if (res.statusCode != 200) {
      final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'No se pudo ajustar');
    }
  }

  // ── Loop #5: dashboard de super admin (referidos) ──────────────────────────

  /// KPIs globales de referidos (solo admin).
  Future<Map<String, dynamic>> adminReferralKpis() async {
    final res = await http.get(Uri.parse('$backendUrl/api/v1/admin/referrals/kpis'), headers: _bearer);
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    return body;
  }

  /// Listado de referidos con filtros y paginación (solo admin).
  Future<Map<String, dynamic>> adminReferralList({
    String? tenantId, String? status, String? dateFrom, String? dateTo,
    String? channel, String? search, int limit = 25, int offset = 0,
  }) async {
    final qp = <String, String>{'limit': '$limit', 'offset': '$offset'};
    if (tenantId != null && tenantId.isNotEmpty) qp['tenant_id'] = tenantId;
    if (status != null && status.isNotEmpty) qp['status'] = status;
    if (dateFrom != null && dateFrom.isNotEmpty) qp['date_from'] = dateFrom;
    if (dateTo != null && dateTo.isNotEmpty) qp['date_to'] = dateTo;
    if (channel != null && channel.isNotEmpty) qp['channel'] = channel;
    if (search != null && search.isNotEmpty) qp['search'] = search;
    final uri = Uri.parse('$backendUrl/api/v1/admin/referrals/list').replace(queryParameters: qp);
    final res = await http.get(uri, headers: _bearer);
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    return body;
  }

  /// Detalle de un referido (solo admin).
  Future<Map<String, dynamic>> adminReferralDetail(String id) async {
    final res = await http.get(Uri.parse('$backendUrl/api/v1/admin/referrals/$id'), headers: _bearer);
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    return body;
  }

  /// Bloquear (fraude) / desbloquear un referido (solo admin).
  Future<void> adminReferralBlock(String id, String reason) async {
    final res = await http.put(Uri.parse('$backendUrl/api/v1/admin/referrals/$id/block'),
        headers: _bearer, body: jsonEncode({'reason': reason}));
    if (res.statusCode != 200) {
      final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'No se pudo bloquear');
    }
  }

  Future<void> adminReferralUnblock(String id) async {
    final res = await http.put(Uri.parse('$backendUrl/api/v1/admin/referrals/$id/unblock'), headers: _bearer);
    if (res.statusCode != 200) {
      final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'No se pudo desbloquear');
    }
  }

  /// Configuración de hitos (lectura/escritura, solo admin).
  Future<Map<String, dynamic>> adminReferralConfig() async {
    final res = await http.get(Uri.parse('$backendUrl/api/v1/admin/referrals/config'), headers: _bearer);
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    return body;
  }

  Future<void> adminReferralConfigUpdate(Map<String, String> changes) async {
    final res = await http.put(Uri.parse('$backendUrl/api/v1/admin/referrals/config'),
        headers: _bearer, body: jsonEncode(changes));
    if (res.statusCode != 200) {
      final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'No se pudo guardar la configuración');
    }
  }

  // ── Loop #5: dashboard de super admin (fraude y auditoría) ─────────────────

  /// Lista unificada de alertas de fraude (referidos + genéricas). Solo admin.
  Future<Map<String, dynamic>> adminFraudAlerts({
    String? severity, String? status, String? type, String? source, int limit = 50, int offset = 0,
  }) async {
    final qp = <String, String>{'limit': '$limit', 'offset': '$offset'};
    if (severity != null && severity.isNotEmpty) qp['severity'] = severity;
    if (status != null && status.isNotEmpty) qp['status'] = status;
    if (type != null && type.isNotEmpty) qp['type'] = type;
    if (source != null && source.isNotEmpty) qp['source'] = source;
    final uri = Uri.parse('$backendUrl/api/v1/admin/fraud/alerts').replace(queryParameters: qp);
    final res = await http.get(uri, headers: _bearer);
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    return body;
  }

  /// Resolver una alerta de fraude con notas (solo admin).
  Future<void> adminFraudResolve(String alertId, String notes, {String? status}) async {
    final payload = <String, dynamic>{'notes': notes};
    if (status != null) payload['status'] = status;
    final res = await http.put(Uri.parse('$backendUrl/api/v1/admin/fraud/alerts/$alertId/resolve'),
        headers: _bearer, body: jsonEncode(payload));
    if (res.statusCode != 200) {
      final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'No se pudo resolver');
    }
  }

  /// Logs de auditoría de acciones administrativas (solo admin).
  Future<Map<String, dynamic>> adminAuditLogs({String? actionType, int limit = 50, int offset = 0}) async {
    final qp = <String, String>{'limit': '$limit', 'offset': '$offset'};
    if (actionType != null && actionType.isNotEmpty) qp['action_type'] = actionType;
    final uri = Uri.parse('$backendUrl/api/v1/admin/audit/logs').replace(queryParameters: qp);
    final res = await http.get(uri, headers: _bearer);
    final body = (res.body.isEmpty ? {} : jsonDecode(res.body)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Error (${res.statusCode})');
    return body;
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

  /// Marca el día de hoy como "día de uso de la app" (para el reto de días).
  /// Idempotente: una fila por (usuario, día) gracias a la PK; si ya existe, se
  /// ignora. Best-effort: si falla (sin red o sin migración), no pasa nada.
  Future<void> pingUsageDay(String tenantId) async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) return;
    final now = DateTime.now();
    final day = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    try {
      await _c.from('app_usage_days').upsert(
        {'tenant_id': tenantId, 'user_id': uid, 'day': day},
        onConflict: 'user_id,day', ignoreDuplicates: true);
    } catch (_) {/* sin red o tabla aún sin crear: no bloquea */}
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

  /// Informe de cierre de jornada para un día concreto (punto 4 + desglose del
  /// punto 5). Si [userId] es null, agrega toda la empresa (la RLS limita).
  /// Los km se calculan como (lectura fin - lectura inicio) por conductor+vehículo;
  /// si un día solo tiene la lectura de inicio, se usa la PRIMERA lectura posterior
  /// (la del día siguiente) como fin -> relleno retroactivo automático.
  Future<DailyReport> dailyReport({String? userId, required DateTime date}) async {
    final start = DateTime(date.year, date.month, date.day);
    final end = start.add(const Duration(days: 1));

    // --- Transacciones del día: ingresos por método, gasto, horas ---
    var tq = _c.from('transactions').select('amount, type, payment_method, created_at');
    if (userId != null) tq = tq.eq('user_id', userId);
    final txRows = (await tq
            .gte('created_at', start.toIso8601String())
            .lt('created_at', end.toIso8601String()) as List)
        .cast<Map<String, dynamic>>();

    double income = 0, expense = 0;
    final byMethod = <String, double>{};
    DateTime? firstTs, lastTs;
    void mark(DateTime? ts) {
      if (ts == null) return;
      if (firstTs == null || ts.isBefore(firstTs!)) firstTs = ts;
      if (lastTs == null || ts.isAfter(lastTs!)) lastTs = ts;
    }
    for (final r in txRows) {
      final amount = (r['amount'] as num?)?.toDouble() ?? 0;
      final ts = DateTime.tryParse((r['created_at'] as String?) ?? '');
      mark(ts);
      if (r['type'] == 'income') {
        income += amount;
        final m = (r['payment_method'] as String?) ?? 'otros';
        byMethod[m] = (byMethod[m] ?? 0) + amount;
      } else {
        expense += amount;
      }
    }

    // --- Km del día: lecturas de odómetro (con relleno retroactivo) ---
    var oq = _c.from('odometer_readings').select('user_id, vehicle_id, reading_km, taken_at');
    if (userId != null) oq = oq.eq('user_id', userId);
    final odoRows = (await oq
            .gte('taken_at', start.toIso8601String())
            .lt('taken_at', end.add(const Duration(days: 30)).toIso8601String())
            .order('taken_at', ascending: true) as List)
        .cast<Map<String, dynamic>>();

    // Agrupa por conductor+vehículo.
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final r in odoRows) {
      final key = '${r['user_id']}|${r['vehicle_id']}';
      (groups[key] ??= []).add(r);
    }
    double totalKm = 0;
    bool anyKnown = false, anyPending = false;
    double? singleStart, singleEnd;
    for (final readings in groups.values) {
      final inDay = readings.where((r) {
        final t = DateTime.tryParse((r['taken_at'] as String?) ?? '');
        return t != null && !t.isBefore(start) && t.isBefore(end);
      }).toList();
      if (inDay.isEmpty) continue;
      mark(DateTime.tryParse((inDay.first['taken_at'] as String?) ?? ''));
      mark(DateTime.tryParse((inDay.last['taken_at'] as String?) ?? ''));
      final kmStart = (inDay.first['reading_km'] as num?)?.toDouble();
      double? kmEnd;
      if (inDay.length >= 2) {
        kmEnd = (inDay.last['reading_km'] as num?)?.toDouble();
      } else {
        // Solo lectura de inicio: usa la primera lectura posterior (día siguiente).
        final next = readings.firstWhere((r) {
          final t = DateTime.tryParse((r['taken_at'] as String?) ?? '');
          return t != null && !t.isBefore(end);
        }, orElse: () => const {});
        if (next.isNotEmpty) kmEnd = (next['reading_km'] as num?)?.toDouble();
      }
      if (kmStart != null && kmEnd != null) {
        final d = kmEnd - kmStart;
        totalKm += d > 0 ? d : 0;
        anyKnown = true;
        singleStart ??= kmStart;
        singleEnd ??= kmEnd;
      } else if (kmStart != null) {
        anyPending = true;
        singleStart ??= kmStart;
      }
    }
    final double? km = anyKnown ? totalKm : (anyPending ? null : null);

    double? hours;
    if (firstTs != null && lastTs != null && lastTs!.isAfter(firstTs!)) {
      hours = lastTs!.difference(firstTs!).inMinutes / 60.0;
    }

    return DailyReport(
      date: start,
      income: income,
      expense: expense,
      incomeByMethod: byMethod,
      km: km,
      kmStart: singleStart,
      kmEnd: singleEnd,
      hours: hours,
    );
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

  /// Lecturas de cuentakilómetros para estadísticas de km (de odometer_readings
  /// y de las carreras con odómetro). Sin límite inferior de fecha: así hay una
  /// lectura previa al rango para calcular bien el primer periodo. Devuelve
  /// {vehicle_id, km, at} sin ordenar (la pantalla agrupa y rellena huecos).
  Future<List<Map<String, dynamic>>> statsOdometer({
    String? driverId,
    String? vehicleId,
    DateTime? to,
  }) async {
    var q1 = _c.from('odometer_readings').select('vehicle_id, reading_km, taken_at');
    if (driverId != null) q1 = q1.eq('user_id', driverId);
    if (vehicleId != null) q1 = q1.eq('vehicle_id', vehicleId);
    if (to != null) q1 = q1.lt('taken_at', to.toIso8601String());
    final r1 = await q1.limit(20000);

    var q2 = _c.from('transactions').select('vehicle_id, odometer_km, created_at')
        .not('odometer_km', 'is', null);
    if (driverId != null) q2 = q2.eq('user_id', driverId);
    if (vehicleId != null) q2 = q2.eq('vehicle_id', vehicleId);
    if (to != null) q2 = q2.lt('created_at', to.toIso8601String());
    final r2 = await q2.limit(20000);

    final out = <Map<String, dynamic>>[];
    for (final r in (r1 as List)) {
      if (r['vehicle_id'] == null || r['reading_km'] == null) continue;
      out.add({'vehicle_id': r['vehicle_id'], 'km': (r['reading_km'] as num).toDouble(), 'at': r['taken_at']});
    }
    for (final r in (r2 as List)) {
      if (r['vehicle_id'] == null || r['odometer_km'] == null) continue;
      out.add({'vehicle_id': r['vehicle_id'], 'km': (r['odometer_km'] as num).toDouble(), 'at': r['created_at']});
    }
    return out;
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

  /// Login con nombre de usuario vía backend (P3-01): el email se resuelve en el
  /// servidor y nunca se expone al cliente. Establece la sesión con el refresh
  /// token devuelto; AuthGate reacciona al cambio. Lanza Exception si falla.
  Future<void> loginWithUsername(String username, String password) async {
    final res = await http.post(
      Uri.parse('$backendUrl/api/v1/auth/login-username'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
    );
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw Exception(body['error'] ?? 'No se pudo iniciar sesión');
    }
    await _c.auth.setSession(body['refresh_token'] as String);
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

  /// Registra la aceptación de los términos legales de la versión indicada.
  Future<void> acceptLegal(int version) async {
    await _c.rpc('accept_legal', params: {'p_version': version});
  }

  // ---------------- Onboarding ----------------
  Future<void> completeOnboarding() async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) return;
    await _c.from('users').update({'has_completed_onboarding': true}).eq('id', uid);
  }
}
