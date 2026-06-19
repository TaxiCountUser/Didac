/// Perfil de aplicación (public.users).
class Profile {
  final String id;
  final String tenantId;
  final String email;
  final String? name;
  final String role; // 'owner' | 'driver'
  final bool hasCompletedOnboarding;

  const Profile({
    required this.id,
    required this.tenantId,
    required this.email,
    required this.role,
    this.name,
    this.hasCompletedOnboarding = false,
  });

  bool get isOwner => role == 'owner';

  factory Profile.fromMap(Map<String, dynamic> m) => Profile(
        id: m['id'] as String,
        tenantId: m['tenant_id'] as String,
        email: m['email'] as String,
        name: m['name'] as String?,
        role: m['role'] as String,
        hasCompletedOnboarding: (m['has_completed_onboarding'] as bool?) ?? false,
      );
}
