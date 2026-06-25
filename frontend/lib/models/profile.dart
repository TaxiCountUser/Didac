/// Perfil de aplicación (public.users).
class Profile {
  final String id;
  final String tenantId;
  final String email;
  final String? name; // lo pone el jefe (lo ve en su panel)
  final String? displayName; // el conductor lo elige para SU app
  final String? licenseNumber; // nº de licencia del conductor
  final String? avatarUrl; // foto del avatar (base64) o null = icono
  final String? username; // para iniciar sesión con usuario (además del correo)
  final String role; // 'owner' | 'driver'
  final bool active; // false = el jefe lo sacó de la flota (despedido)
  final bool hasCompletedOnboarding;

  const Profile({
    required this.id,
    required this.tenantId,
    required this.email,
    required this.role,
    this.name,
    this.displayName,
    this.licenseNumber,
    this.avatarUrl,
    this.username,
    this.active = true,
    this.hasCompletedOnboarding = false,
  });

  bool get isOwner => role == 'owner';

  /// Conductor que el jefe sacó de la flota: solo puede ver la pantalla de aviso.
  bool get isInactiveDriver => role == 'driver' && !active;

  /// Nombre a mostrar en la app del propio usuario: su display_name si lo
  /// tiene, si no el que le puso el jefe, y si no, el email.
  String get appName {
    if (displayName != null && displayName!.trim().isNotEmpty) return displayName!.trim();
    if (name != null && name!.trim().isNotEmpty) return name!.trim();
    return email;
  }

  factory Profile.fromMap(Map<String, dynamic> m) => Profile(
        id: m['id'] as String,
        tenantId: m['tenant_id'] as String,
        email: m['email'] as String,
        name: m['name'] as String?,
        displayName: m['display_name'] as String?,
        licenseNumber: m['license_number'] as String?,
        avatarUrl: m['avatar_url'] as String?,
        username: m['username'] as String?,
        role: m['role'] as String,
        active: (m['active'] as bool?) ?? true,
        hasCompletedOnboarding: (m['has_completed_onboarding'] as bool?) ?? false,
      );
}
