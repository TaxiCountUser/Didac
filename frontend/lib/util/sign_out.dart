import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/push_service.dart';

/// Cierre de sesión de la app: primero desapunta este móvil de la cuenta que sale
/// (para que deje de recibir sus notificaciones aquí) y luego cierra la sesión.
/// Usar SIEMPRE esto en lugar de `Supabase.instance.client.auth.signOut()`.
Future<void> appSignOut() async {
  await PushService.instance.unlinkCurrentUser();
  await Supabase.instance.client.auth.signOut();
}
