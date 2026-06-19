import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../models/profile.dart';

/// Acceso a datos vía Supabase (respetando RLS) y al backend Fastify.
class DataService {
  SupabaseClient get _c => Supabase.instance.client;

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

  // ---------------- Onboarding ----------------
  Future<void> completeOnboarding() async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) return;
    await _c.from('users').update({'has_completed_onboarding': true}).eq('id', uid);
  }
}
