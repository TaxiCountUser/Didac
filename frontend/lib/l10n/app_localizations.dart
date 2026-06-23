import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Idiomas soportados (ES por defecto).
const kSupportedLocales = [Locale('es'), Locale('en'), Locale('ca')];

const kLanguageNames = {'es': 'Español', 'en': 'English', 'ca': 'Català'};

/// Controlador global del idioma: persiste la elección y notifica a MaterialApp.
class LocaleController extends ValueNotifier<Locale> {
  LocaleController() : super(const Locale('es'));
  static const _prefKey = 'app_locale';

  Future<void> load() async {
    try {
      final code = (await SharedPreferences.getInstance()).getString(_prefKey);
      if (code != null && kSupportedLocales.any((l) => l.languageCode == code)) {
        value = Locale(code);
      }
    } catch (_) {/* sin persistencia: queda ES */}
  }

  Future<void> setLocale(String code) async {
    value = Locale(code);
    try {
      await (await SharedPreferences.getInstance()).setString(_prefKey, code);
    } catch (_) {}
  }
}

final localeController = LocaleController();

/// Localización propia basada en mapas. Acceso: `context.l10n.t('clave')`.
/// Si falta una clave en el idioma actual, cae a español y, si no, a la clave.
class AppLocalizations {
  final Locale locale;
  AppLocalizations(this.locale);

  static AppLocalizations of(BuildContext context) =>
      Localizations.of<AppLocalizations>(context, AppLocalizations)!;

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();

  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = [
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];

  String t(String key, [Map<String, String>? args]) {
    final lang = locale.languageCode;
    var s = _values[lang]?[key] ?? _values['es']?[key] ?? key;
    if (args != null) {
      args.forEach((k, v) => s = s.replaceAll('{$k}', v));
    }
    return s;
  }
}

extension L10nX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();
  @override
  bool isSupported(Locale locale) =>
      kSupportedLocales.any((l) => l.languageCode == locale.languageCode);
  @override
  Future<AppLocalizations> load(Locale locale) async => AppLocalizations(locale);
  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

// ============================================================
// Traducciones. Clave -> texto por idioma.
// ============================================================
const Map<String, Map<String, String>> _values = {
  'es': {
    // Común
    'save': 'Guardar', 'cancel': 'Cancelar', 'delete': 'Eliminar', 'edit': 'Editar',
    'retry': 'Reintentar', 'ok': 'OK', 'send': 'Enviar', 'close': 'Cerrar',
    'logout': 'Cerrar sesión', 'settings': 'Ajustes', 'error': 'Error',
    'income': 'Ingreso', 'expense': 'Gasto', 'all': 'Todos',
    // Login
    'login_email': 'Email', 'login_password': 'Contraseña', 'login_enter': 'Entrar',
    'login_register': 'Crear cuenta', 'login_company': 'Nombre de la empresa',
    'login_name': 'Tu nombre', 'login_have_account': '¿Ya tienes cuenta? Entra',
    'login_no_account': '¿No tienes cuenta? Regístrate',
    // Driver home
    'dh_hello': '¡Hola, {name}!',
    'dh_add_record': 'Añadir registro', 'dh_add_record_sub': 'Carrera o gasto (voz o manual)',
    'dh_view_tx': 'Ver transacciones', 'dh_view_tx_sub': 'Tu historial de carreras y gastos',
    'dh_end_day': 'Finalizar jornada (km)',
    'dh_start_day': 'Empezar jornada', 'dh_finish_day': 'Finalizar jornada',
    'dh_vehicle': 'Vehículo', 'dh_vehicle_today': 'Vehículo de hoy',
    'dh_km_now': 'Km actuales del coche', 'dh_not_now': 'Ahora no',
    'dh_km_saved': 'Km guardados', 'dh_no_vehicles': 'No tienes vehículos asignados.',
    // Settings
    'set_title': 'Ajustes', 'set_language': 'Idioma',
    'set_more_langs': 'Cambia el idioma de la app.',
    'set_report_bug': 'Reportar un fallo de la app', 'set_report_bug_sub': 'Cuéntanos qué ha ido mal',
    'set_incidents_owner': 'Incidencias de la flota',
    'set_incidents_owner_sub': 'Mensajes e incidencias de tus conductores',
    'set_incidents_driver': 'Mensajes al jefe',
    'set_incidents_driver_sub': 'Deja una nota o incidencia al jefe',
    'set_about': 'Acerca de',
    'bug_title': 'Reportar un fallo de la app',
    'bug_hint': 'Describe el problema: qué hacías y qué ha fallado',
    'bug_thanks': '¡Gracias! Incidencia registrada',
    // Incidents
    'inc_to_boss': 'Mensaje al jefe',
    'inc_hint': 'Ej.: hoy escuché un ruido raro en la rueda derecha',
    'inc_sent': 'Mensaje enviado al jefe',
    'inc_none_owner': 'No hay incidencias.',
    'inc_none_driver': 'No has enviado ninguna incidencia.\nPulsa "Mensaje al jefe".',
    'inc_app_bug': 'Fallo de la app', 'inc_resolve': 'Resolver',
    'inc_resolved': 'Resuelta', 'inc_open': 'Abierta',
    // Owner nav
    'nav_dashboard': 'Panel de control', 'nav_vehicles': 'Vehículos',
    'nav_drivers': 'Conductores', 'nav_incidents': 'Incidencias', 'nav_subscription': 'Suscripción',
    // Ajustes (cabecera + acciones)
    'set_active_vehicle': 'Vehículo activo', 'set_no_vehicle': 'Sin vehículo activo',
    'set_change_vehicle': 'Cambiar vehículo activo', 'set_change_account': 'Cambiar de cuenta',
    'set_edit_name': 'Editar mi nombre', 'set_name_hint': 'Nombre que verás en tu app',
    'set_name_updated': 'Nombre actualizado', 'set_company': 'Empresa',
    'set_license': 'Nº de licencia', 'set_soon': 'Próximamente',
    'set_locate_vehicle': 'Localizar vehículo', 'set_subscription_sub': 'Plan activo y mejorar plan',
    'set_locate_sub': 'Buscar un conductor por ubicación',
    // Login extra
    'login_subtitle_signin': 'Iniciar sesión',
    'login_subtitle_signup': 'Crear cuenta de propietario',
    'login_company_fleet': 'Nombre de la empresa / flota',
    'login_btn_register': 'Registrarse', 'login_btn_enter': 'Entrar',
    'login_toggle_to_signin': '¿Ya tienes cuenta? Inicia sesión',
    'login_toggle_to_signup': '¿Eres propietario? Crea tu cuenta',
    // Añadir registro
    'ar_title': 'Añadir registro', 'ar_manual': 'Manual', 'ar_voice': 'Voz',
    'ar_review': 'Revisa los datos y guarda',
    // Historial chofer
    'dt_title': 'Mis transacciones', 'dt_empty': 'No hay transacciones en este periodo.',
    'per_day': 'Día', 'per_week': 'Semana', 'per_month': 'Mes', 'per_year': 'Año',
  },
  'en': {
    'save': 'Save', 'cancel': 'Cancel', 'delete': 'Delete', 'edit': 'Edit',
    'retry': 'Retry', 'ok': 'OK', 'send': 'Send', 'close': 'Close',
    'logout': 'Log out', 'settings': 'Settings', 'error': 'Error',
    'income': 'Income', 'expense': 'Expense', 'all': 'All',
    'login_email': 'Email', 'login_password': 'Password', 'login_enter': 'Sign in',
    'login_register': 'Create account', 'login_company': 'Company name',
    'login_name': 'Your name', 'login_have_account': 'Already have an account? Sign in',
    'login_no_account': "Don't have an account? Sign up",
    'dh_hello': 'Hi, {name}!',
    'dh_add_record': 'Add record', 'dh_add_record_sub': 'Trip or expense (voice or manual)',
    'dh_view_tx': 'View transactions', 'dh_view_tx_sub': 'Your trips and expenses history',
    'dh_end_day': 'End shift (km)',
    'dh_start_day': 'Start shift', 'dh_finish_day': 'End shift',
    'dh_vehicle': 'Vehicle', 'dh_vehicle_today': "Today's vehicle",
    'dh_km_now': 'Current car mileage', 'dh_not_now': 'Not now',
    'dh_km_saved': 'Mileage saved', 'dh_no_vehicles': 'You have no assigned vehicles.',
    'set_title': 'Settings', 'set_language': 'Language',
    'set_more_langs': 'Change the app language.',
    'set_report_bug': 'Report an app bug', 'set_report_bug_sub': 'Tell us what went wrong',
    'set_incidents_owner': 'Fleet incidents',
    'set_incidents_owner_sub': 'Messages and incidents from your drivers',
    'set_incidents_driver': 'Messages to the boss',
    'set_incidents_driver_sub': 'Leave a note or incident for the boss',
    'set_about': 'About',
    'bug_title': 'Report an app bug',
    'bug_hint': 'Describe the problem: what you were doing and what failed',
    'bug_thanks': 'Thanks! Incident logged',
    'inc_to_boss': 'Message to the boss',
    'inc_hint': 'E.g.: today I heard a weird noise in the right wheel',
    'inc_sent': 'Message sent to the boss',
    'inc_none_owner': 'No incidents.',
    'inc_none_driver': 'You have not sent any incident.\nTap "Message to the boss".',
    'inc_app_bug': 'App bug', 'inc_resolve': 'Resolve',
    'inc_resolved': 'Resolved', 'inc_open': 'Open',
    'nav_dashboard': 'Control panel', 'nav_vehicles': 'Vehicles',
    'nav_drivers': 'Drivers', 'nav_incidents': 'Incidents', 'nav_subscription': 'Subscription',
    'set_active_vehicle': 'Active vehicle', 'set_no_vehicle': 'No active vehicle',
    'set_change_vehicle': 'Change active vehicle', 'set_change_account': 'Switch account',
    'set_edit_name': 'Edit my name', 'set_name_hint': 'Name shown in your app',
    'set_name_updated': 'Name updated', 'set_company': 'Company',
    'set_license': 'License number', 'set_soon': 'Coming soon',
    'set_locate_vehicle': 'Locate vehicle', 'set_subscription_sub': 'Active plan and upgrade',
    'set_locate_sub': 'Find a driver by location',
    'login_subtitle_signin': 'Sign in',
    'login_subtitle_signup': 'Create owner account',
    'login_company_fleet': 'Company / fleet name',
    'login_btn_register': 'Sign up', 'login_btn_enter': 'Sign in',
    'login_toggle_to_signin': 'Already have an account? Sign in',
    'login_toggle_to_signup': 'Are you an owner? Create your account',
    'ar_title': 'Add record', 'ar_manual': 'Manual', 'ar_voice': 'Voice',
    'ar_review': 'Review the data and save',
    'dt_title': 'My transactions', 'dt_empty': 'No transactions in this period.',
    'per_day': 'Day', 'per_week': 'Week', 'per_month': 'Month', 'per_year': 'Year',
  },
  'ca': {
    'save': 'Desa', 'cancel': 'Cancel·la', 'delete': 'Elimina', 'edit': 'Edita',
    'retry': 'Torna-ho a provar', 'ok': "D'acord", 'send': 'Envia', 'close': 'Tanca',
    'logout': 'Tanca la sessió', 'settings': 'Configuració', 'error': 'Error',
    'income': 'Ingrés', 'expense': 'Despesa', 'all': 'Tots',
    'login_email': 'Correu', 'login_password': 'Contrasenya', 'login_enter': 'Entra',
    'login_register': 'Crea un compte', 'login_company': "Nom de l'empresa",
    'login_name': 'El teu nom', 'login_have_account': 'Ja tens compte? Entra',
    'login_no_account': 'No tens compte? Registra’t',
    'dh_hello': 'Hola, {name}!',
    'dh_add_record': 'Afegir registre', 'dh_add_record_sub': 'Cursa o despesa (veu o manual)',
    'dh_view_tx': 'Veure transaccions', 'dh_view_tx_sub': "L'historial de curses i despeses",
    'dh_end_day': 'Finalitzar jornada (km)',
    'dh_start_day': 'Començar jornada', 'dh_finish_day': 'Finalitzar jornada',
    'dh_vehicle': 'Vehicle', 'dh_vehicle_today': "Vehicle d'avui",
    'dh_km_now': 'Km actuals del cotxe', 'dh_not_now': 'Ara no',
    'dh_km_saved': 'Km desats', 'dh_no_vehicles': 'No tens vehicles assignats.',
    'set_title': 'Configuració', 'set_language': 'Idioma',
    'set_more_langs': "Canvia l'idioma de l'app.",
    'set_report_bug': "Informar d'un error de l'app", 'set_report_bug_sub': 'Explica què ha anat malament',
    'set_incidents_owner': 'Incidències de la flota',
    'set_incidents_owner_sub': 'Missatges i incidències dels teus conductors',
    'set_incidents_driver': 'Missatges al cap',
    'set_incidents_driver_sub': 'Deixa una nota o incidència al cap',
    'set_about': 'Quant a',
    'bug_title': "Informar d'un error de l'app",
    'bug_hint': 'Descriu el problema: què feies i què ha fallat',
    'bug_thanks': 'Gràcies! Incidència registrada',
    'inc_to_boss': 'Missatge al cap',
    'inc_hint': 'Ex.: avui he sentit un soroll estrany a la roda dreta',
    'inc_sent': 'Missatge enviat al cap',
    'inc_none_owner': 'No hi ha incidències.',
    'inc_none_driver': 'No has enviat cap incidència.\nPrem "Missatge al cap".',
    'inc_app_bug': "Error de l'app", 'inc_resolve': 'Resol',
    'inc_resolved': 'Resolta', 'inc_open': 'Oberta',
    'nav_dashboard': 'Tauler de control', 'nav_vehicles': 'Vehicles',
    'nav_drivers': 'Conductors', 'nav_incidents': 'Incidències', 'nav_subscription': 'Subscripció',
    'set_active_vehicle': 'Vehicle actiu', 'set_no_vehicle': 'Sense vehicle actiu',
    'set_change_vehicle': 'Canvia el vehicle actiu', 'set_change_account': 'Canvia de compte',
    'set_edit_name': 'Edita el meu nom', 'set_name_hint': "Nom que veuràs a la teva app",
    'set_name_updated': 'Nom actualitzat', 'set_company': 'Empresa',
    'set_license': 'Núm. de llicència', 'set_soon': 'Properament',
    'set_locate_vehicle': 'Localitza vehicle', 'set_subscription_sub': 'Pla actiu i millora',
    'set_locate_sub': 'Cerca un conductor per ubicació',
    'login_subtitle_signin': 'Inicia la sessió',
    'login_subtitle_signup': 'Crea un compte de propietari',
    'login_company_fleet': "Nom de l'empresa / flota",
    'login_btn_register': 'Registra’t', 'login_btn_enter': 'Entra',
    'login_toggle_to_signin': 'Ja tens compte? Inicia la sessió',
    'login_toggle_to_signup': 'Ets propietari? Crea el teu compte',
    'ar_title': 'Afegir registre', 'ar_manual': 'Manual', 'ar_voice': 'Veu',
    'ar_review': 'Revisa les dades i desa',
    'dt_title': 'Les meves transaccions', 'dt_empty': 'No hi ha transaccions en aquest període.',
    'per_day': 'Dia', 'per_week': 'Setmana', 'per_month': 'Mes', 'per_year': 'Any',
  },
};
