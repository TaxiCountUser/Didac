/// Perfil de aplicación (public.users).
class Profile {
  final String id;
  final String tenantId; // '' = pendiente: aún no pertenece a ninguna flota
  final String email;
  final String? name; // lo pone el jefe (lo ve en su panel)
  final String? displayName; // el conductor lo elige para SU app
  final String? licenseNumber; // nº de licencia del conductor
  final String? avatarUrl; // foto del avatar (base64) o null = icono
  final String? username; // para iniciar sesión con usuario (además del correo)
  final String role; // 'owner' | 'driver'
  final bool active; // false = el jefe lo sacó de la flota (despedido)
  final bool isAdmin; // admin de plataforma: ve/resuelve incidencias de todas
  final bool hasCompletedOnboarding;
  final bool tutorialSeen; // ya vio el tutorial de bienvenida (una sola vez)
  final String? referralCode; // mi código para invitar
  final String? referredBy; // id de quien me invitó (null = nadie)

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
    this.isAdmin = false,
    this.hasCompletedOnboarding = false,
    this.tutorialSeen = false,
    this.referralCode,
    this.referredBy,
  });

  bool get isOwner => role == 'owner';

  /// ¿Pertenece ya a una flota? Si no, la app le pide crear empresa o unirse.
  bool get hasFleet => tenantId.isNotEmpty;

  /// Conductor que el jefe sacó de la flota: solo puede ver la pantalla de aviso.
  bool get isInactiveDriver => role == 'driver' && hasFleet && !active;

  /// Nombre a mostrar en la app del propio usuario: su display_name si lo
  /// tiene, si no el que le puso el jefe, y si no, el email.
  String get appName {
    if (displayName != null && displayName!.trim().isNotEmpty) return displayName!.trim();
    if (name != null && name!.trim().isNotEmpty) return name!.trim();
    return email;
  }

  factory Profile.fromMap(Map<String, dynamic> m) => Profile(
        id: m['id'] as String,
        tenantId: (m['tenant_id'] as String?) ?? '',
        email: m['email'] as String,
        name: m['name'] as String?,
        displayName: m['display_name'] as String?,
        licenseNumber: m['license_number'] as String?,
        avatarUrl: m['avatar_url'] as String?,
        username: m['username'] as String?,
        role: m['role'] as String,
        active: (m['active'] as bool?) ?? true,
        isAdmin: (m['is_admin'] as bool?) ?? false,
        hasCompletedOnboarding: (m['has_completed_onboarding'] as bool?) ?? false,
        tutorialSeen: (m['tutorial_seen'] as bool?) ?? false,
        referralCode: m['referral_code'] as String?,
        referredBy: m['referred_by'] as String?,
      );
}
