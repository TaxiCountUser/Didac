// ============================================================================
// Registro de mejoras por versión ("Novedades" / "Quant a"), filtrado por rol.
//
// Ámbito de cada mejora (a quién le interesa):
//   - driver: afecta a conductores  -> la ven CONDUCTORES y JEFES.
//   - owner : solo afecta al jefe    -> solo la ve el JEFE.
//   - admin : solo el panel de admin -> NO se muestra en Novedades.
//
// Para añadir una versión nueva: mete una entrada arriba del todo (más reciente
// primero) con sus ítems y el ámbito correcto de cada uno.
// ============================================================================

enum ChangeScope { driver, owner, admin }

class ChangeItem {
  final ChangeScope scope;
  final String es;
  final String en;
  final String ca;
  const ChangeItem(this.scope, {required this.es, required this.en, required this.ca});

  String text(String lang) => lang == 'en' ? en : (lang == 'ca' ? ca : es);
}

class ChangeVersion {
  final String version;
  final String date; // dd/MM/yyyy
  final List<ChangeItem> items;
  const ChangeVersion(this.version, this.date, this.items);
}

/// Historial (más reciente primero). Amplíalo en cada release.
const List<ChangeVersion> kChangelog = [
  ChangeVersion('0.1.69', '14/07/2026', [
    ChangeItem(ChangeScope.driver,
        es: 'Mensajes con el jefe: ahora es un chat directo. El jefe ve a todos sus conductores y chatea con cada uno; el conductor chatea con su jefe.',
        en: 'Messaging with the boss: now a direct chat. The boss sees all drivers and chats with each one; drivers chat with their boss.',
        ca: 'Missatges amb el cap: ara és un xat directe. El cap veu tots els seus conductors i xateja amb cadascun; el conductor xateja amb el seu cap.'),
  ]),
  ChangeVersion('0.1.65', '14/07/2026', [
    ChangeItem(ChangeScope.driver,
        es: 'Notificaciones: ahora la app pide permiso y puedes activarlas desde Ajustes (avisos de mensajes y novedades).',
        en: 'Notifications: the app now asks for permission and you can enable them from Settings (message and news alerts).',
        ca: 'Notificacions: ara l\'app demana permís i pots activar-les des d\'Ajustos (avisos de missatges i novetats).'),
  ]),
  ChangeVersion('0.1.63', '13/07/2026', [
    ChangeItem(ChangeScope.driver,
        es: 'Al grabar por voz se ven las ondas de sonido: así sabes que está grabando.',
        en: 'When recording by voice you now see sound waves, so you know it is recording.',
        ca: 'En gravar per veu es veuen les ones de so: així saps que està gravant.'),
    ChangeItem(ChangeScope.driver,
        es: 'Corregido el micrófono en la versión web (ya transcribe sin error).',
        en: 'Fixed the microphone on the web version (it now transcribes without error).',
        ca: 'Corregit el micròfon a la versió web (ja transcriu sense error).'),
    ChangeItem(ChangeScope.owner,
        es: 'En el pago puedes ajustar el número de conductores que contratas.',
        en: 'At checkout you can adjust the number of drivers you pay for.',
        ca: 'En el pagament pots ajustar el nombre de conductors que contractes.'),
    ChangeItem(ChangeScope.owner,
        es: 'Ahorro: se explica mejor: por retos ganas 1 mes por ese conductor; por referidos, días para toda la flota.',
        en: 'Savings explained better: challenges earn 1 month for that driver; referrals earn days for the whole fleet.',
        ca: 'Estalvi explicat millor: per reptes guanyes 1 mes per aquell conductor; per referits, dies per a tota la flota.'),
  ]),
  ChangeVersion('0.1.62', '13/07/2026', [
    ChangeItem(ChangeScope.owner,
        es: 'Al entrar en Suscripción se muestra el cupón de descuento activo con un botón para copiarlo.',
        en: 'When you open Subscription, the active discount coupon is shown with a button to copy it.',
        ca: 'En entrar a Subscripció es mostra el cupó de descompte actiu amb un botó per copiar-lo.'),
  ]),
  ChangeVersion('0.1.60', '13/07/2026', [
    ChangeItem(ChangeScope.owner,
        es: 'Precios por conductor: 2,50 €/mes o 30 €/año; máximo 100 conductores.',
        en: 'Per-driver pricing: €2.50/month or €30/year; up to 100 drivers.',
        ca: 'Preus per conductor: 2,50 €/mes o 30 €/any; màxim 100 conductors.'),
    ChangeItem(ChangeScope.driver,
        es: 'Aviso dentro de la app cuando hay una versión nueva disponible.',
        en: 'In-app notice when a new version is available.',
        ca: 'Avís dins l\'app quan hi ha una versió nova disponible.'),
  ]),
];

/// Novedades visibles para un rol. El jefe (owner) ve las de conductor y las
/// suyas; el conductor solo las de conductor. Las de admin nunca se muestran.
/// Devuelve solo versiones que tengan algún ítem visible.
List<ChangeVersion> changelogFor({required bool isOwner}) {
  bool visible(ChangeScope s) =>
      s == ChangeScope.driver || (isOwner && s == ChangeScope.owner);
  final out = <ChangeVersion>[];
  for (final v in kChangelog) {
    final items = v.items.where((i) => visible(i.scope)).toList();
    if (items.isNotEmpty) out.add(ChangeVersion(v.version, v.date, items));
  }
  return out;
}
