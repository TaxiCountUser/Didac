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

  /// Etiqueta de categoría de gasto localizada (con fallback al propio código).
  String catLabel(String? cat) {
    if (cat == null || cat.isEmpty) return t('uncategorized');
    final lang = locale.languageCode;
    return _values[lang]?['cat_$cat'] ?? _values['es']?['cat_$cat'] ?? cat;
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
    'set_change_vehicle_sub': 'Elige entre los vehículos que te ha asignado la empresa',
    'set_edit_name': 'Editar mi nombre', 'set_name_hint': 'Nombre que verás en tu app',
    'set_name_updated': 'Nombre actualizado', 'set_company': 'Empresa',
    'set_license': 'Nº de licencia', 'set_soon': 'Próximamente',
    'set_locate_vehicle': 'Localizar vehículo', 'set_subscription_sub': 'Plan activo y mejorar plan',
    'set_locate_sub': 'Buscar un conductor por ubicación',
    'loc_none': 'Ningún conductor ha compartido su ubicación todavía.',
    'loc_open_map': 'Ver en el mapa', 'loc_accuracy': 'precisión',
    'loc_last_conn': 'Última conexión', 'loc_now': 'ahora mismo',
    'loc_min': 'hace {n} min', 'loc_hours': 'hace {n} h', 'loc_days': 'hace {n} d',
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
    // Categorías / cliente
    'uncategorized': 'Sin categoría', 'particular': 'Particular',
    'cat_gasolina': 'Gasolina', 'cat_gasoil': 'Gasoil', 'cat_taller': 'Taller',
    'cat_peaje': 'Peaje', 'cat_parking': 'Parking', 'cat_lavado': 'Lavado',
    'cat_compra': 'Compra', 'cat_ingreso_tarjeta': 'Ingreso', 'cat_otros': 'Otros',
    // Formulario de registro
    'ti_new': 'Nueva transacción', 'ti_edit': 'Editar transacción', 'ti_review': 'Revisar transacción',
    'ti_trip': 'Carrera', 'ti_expense': 'Gasto', 'ti_price': 'Precio', 'ti_amount': 'Importe',
    'ti_datetime': 'Fecha y hora', 'ti_payment': 'Método de pago', 'ti_card': 'Tarjeta', 'ti_cash': 'Efectivo',
    'ti_desc': 'Descripción (opcional)', 'ti_save': 'Guardar', 'ti_save_changes': 'Guardar cambios',
    'ti_confirm_save': 'Confirmar y guardar', 'ti_origin': 'Origen', 'ti_destination': 'Destino',
    'ti_km': 'Km del coche (opcional)', 'ti_client': 'Cliente / empresa',
    'ti_client_help': 'Vacío = cliente particular', 'ti_category': 'Categoría', 'ti_vehicle': 'Vehículo',
    'ti_dictate': 'Dictar por voz', 'ti_invalid_amount': 'Introduce un importe válido',
    'ti_invalid_km': 'Los km deben ser un número entero', 'ti_trip_saved': 'Carrera guardada',
    'ti_expense_saved': 'Gasto guardado', 'ti_updated': 'Transacción actualizada',
    'ti_blocked': 'Operación bloqueada. Contacta con el administrador de la flota',
    // Detalle
    'td_title': 'Detalle', 'td_income': 'Ingreso', 'td_expense': 'Gasto', 'td_category': 'Categoría',
    'td_datetime': 'Fecha y hora', 'td_payment': 'Método de pago', 'td_driver': 'Conductor',
    'td_vehicle': 'Vehículo', 'td_route': 'Trayecto', 'td_client': 'Cliente', 'td_km': 'Km del coche',
    'td_desc': 'Descripción', 'td_del_title': 'Eliminar transacción',
    'td_del_msg': '¿Seguro que quieres eliminar esta transacción? Esta acción no se puede deshacer.',
    'td_not_found': 'Transacción no encontrada', 'td_profile_fail': 'No se pudo cargar el perfil',
    // Voz
    'vc_tap': 'Pulsa el micrófono y dicta tu carrera',
    'vc_example': 'Ej.: "carrera de Sants a la Sagrera por 18 euros con tarjeta de Movitaxi"',
    'vc_recording': 'Grabando… pulsa para terminar', 'vc_transcribing': 'Transcribiendo…',
    'vc_no_perm': 'Sin permiso de micrófono', 'vc_start_fail': 'No se pudo iniciar la grabación',
    'vc_no_audio': 'No se grabó audio', 'vc_transcribe_err': 'Error al transcribir',
    'vc_mock': 'Transcripción de ejemplo (configura OpenAI para la voz real)',
    // Dashboard / panel
    'od_summary': 'Resumen de la flota', 'od_export': 'Exportar',
    'od_export_excel': 'Exportar Excel', 'od_export_pdf': 'Exportar PDF',
    'od_generating': 'Generando informe {fmt}…', 'od_generated': 'Informe generado',
    'od_billing': 'Tu suscripción no está activa. Actualiza tu método de pago para seguir usando TaxiCount.',
    'od_search': 'Buscar por empresa (p. ej. Gitaxi)', 'od_today': 'Hoy', 'od_custom': 'Personalizado',
    'od_driver': 'Conductor', 'od_vehicle': 'Vehículo', 'od_kpi_income': 'Ingresos',
    'od_kpi_expense': 'Gastos', 'od_kpi_balance': 'Balance', 'od_transactions': 'Transacciones',
    'od_no_tx': 'No hay transacciones para este filtro.', 'od_expenses_chart': 'Gastos por categoría',
    'od_no_expenses': 'Sin gastos en este periodo.', 'od_new_record': 'Nuevo registro de {name}',
    // Vehículos
    'vh_add': 'Añadir', 'vh_new': 'Nuevo vehículo', 'vh_plate': 'Matrícula', 'vh_model': 'Modelo',
    'vh_empty': 'No hay vehículos. Añade el primero.', 'vh_no_model': 'Sin modelo',
    'vh_drivers_of': 'Choferes de {plate}', 'vh_no_drivers': 'No hay conductores. Invita alguno primero.',
    'vh_assign_saved': 'Asignación guardada',
    // Ficha de vehículo + mantenimiento
    'vh_detail': 'Ficha del vehículo', 'vh_km_current': 'Km actuales', 'vh_km_unknown': 'Sin lecturas de km',
    'vh_assign_drivers': 'Asignar conductores', 'vh_maintenance': 'Mantenimiento',
    'vh_itv': 'ITV', 'vh_insurance': 'Seguro', 'vh_transport_card': 'Tarjeta de transporte',
    'vh_revisions': 'Revisiones', 'vh_edit_maintenance': 'Editar mantenimiento',
    'vh_next': 'Próxima', 'vh_overdue': '¡Caducada!', 'vh_today': 'Hoy',
    'vh_in_days': 'en {n} días', 'vh_ago_days': 'hace {n} días', 'vh_no_data': 'Sin datos',
    'vh_km_at_revision': 'Km en la última revisión', 'vh_revision_interval': 'Cada cuántos km',
    'vh_revision_next': 'Próxima revisión', 'vh_km_left': 'faltan {n} km', 'vh_km_over': '¡{n} km de más!',
    'vh_transport_years': 'Validez (años)', 'vh_maintenance_notes': 'Notas (avería, taller…)',
    'vh_maintenance_saved': 'Mantenimiento guardado', 'vh_set_km_hint': 'Pon los km actuales del coche para calcular la revisión',
    'vh_date_itv': 'Próxima ITV', 'vh_date_insurance': 'Renovación del seguro',
    'vh_date_transport': 'Último visado de la tarjeta', 'vh_pick_date': 'Elegir fecha', 'vh_clear': 'Quitar',
    // Conductores
    'dr_invite': 'Invitar', 'dr_invite_title': 'Invitar conductor', 'dr_email': 'Email', 'dr_name': 'Nombre',
    'dr_empty': 'Aún no hay conductores. Invita al primero.', 'dr_invited_title': 'Conductor invitado',
    'dr_invited_msg': 'Se ha creado el conductor.\n\nContraseña temporal (desarrollo):\n{pwd}',
    'dr_vehicles_of': 'Vehículos de {name}', 'dr_no_vehicles': 'No hay vehículos. Añade alguno primero.',
    // Onboarding
    'ob_title': 'Bienvenido a TaxiCount', 'ob_lets_start': '¡Empecemos! 🚕',
    'ob_intro': 'Configura tu flota en dos pasos. Puedes hacerlo ahora o más tarde.',
    'ob_step1': '1. Añade tu primer vehículo', 'ob_step2': '2. Invita a tu primer conductor',
    'ob_finish': 'Finalizar configuración',
    // Suscripción
    'sub_change_plan': 'Cambiar de plan', 'sub_choose_plan': 'Elige un plan', 'sub_no_plan': 'Sin plan',
    'sub_drivers_included': 'Conductores incluidos: {n}', 'sub_unlimited': 'Ilimitados',
    'sub_inactive_msg': 'Tu suscripción no está activa. Contrata o reactiva un plan para seguir registrando transacciones.',
    'sub_manage_billing': 'Gestionar facturación', 'sub_current': 'Actual', 'sub_choose': 'Elegir',
    'sub_plan_prefix': 'Plan', 'sub_no_browser': 'No se pudo abrir el navegador',
    'st_active': 'Activa', 'st_trial': 'Periodo de prueba', 'st_past_due': 'Pago pendiente',
    'st_canceled': 'Cancelada', 'st_inactive': 'Inactiva',
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
    'set_change_vehicle_sub': 'Pick one of the vehicles the company assigned to you',
    'set_edit_name': 'Edit my name', 'set_name_hint': 'Name shown in your app',
    'set_name_updated': 'Name updated', 'set_company': 'Company',
    'set_license': 'License number', 'set_soon': 'Coming soon',
    'set_locate_vehicle': 'Locate vehicle', 'set_subscription_sub': 'Active plan and upgrade',
    'set_locate_sub': 'Find a driver by location',
    'loc_none': 'No driver has shared their location yet.',
    'loc_open_map': 'View on map', 'loc_accuracy': 'accuracy',
    'loc_last_conn': 'Last connection', 'loc_now': 'just now',
    'loc_min': '{n} min ago', 'loc_hours': '{n} h ago', 'loc_days': '{n} d ago',
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
    'uncategorized': 'No category', 'particular': 'Private',
    'cat_gasolina': 'Petrol', 'cat_gasoil': 'Diesel', 'cat_taller': 'Garage',
    'cat_peaje': 'Toll', 'cat_parking': 'Parking', 'cat_lavado': 'Car wash',
    'cat_compra': 'Purchase', 'cat_ingreso_tarjeta': 'Income', 'cat_otros': 'Other',
    'ti_new': 'New transaction', 'ti_edit': 'Edit transaction', 'ti_review': 'Review transaction',
    'ti_trip': 'Trip', 'ti_expense': 'Expense', 'ti_price': 'Price', 'ti_amount': 'Amount',
    'ti_datetime': 'Date and time', 'ti_payment': 'Payment method', 'ti_card': 'Card', 'ti_cash': 'Cash',
    'ti_desc': 'Description (optional)', 'ti_save': 'Save', 'ti_save_changes': 'Save changes',
    'ti_confirm_save': 'Confirm and save', 'ti_origin': 'Origin', 'ti_destination': 'Destination',
    'ti_km': 'Car mileage (optional)', 'ti_client': 'Client / company',
    'ti_client_help': 'Empty = private client', 'ti_category': 'Category', 'ti_vehicle': 'Vehicle',
    'ti_dictate': 'Dictate by voice', 'ti_invalid_amount': 'Enter a valid amount',
    'ti_invalid_km': 'Mileage must be a whole number', 'ti_trip_saved': 'Trip saved',
    'ti_expense_saved': 'Expense saved', 'ti_updated': 'Transaction updated',
    'ti_blocked': 'Operation blocked. Contact the fleet administrator',
    'td_title': 'Detail', 'td_income': 'Income', 'td_expense': 'Expense', 'td_category': 'Category',
    'td_datetime': 'Date and time', 'td_payment': 'Payment method', 'td_driver': 'Driver',
    'td_vehicle': 'Vehicle', 'td_route': 'Route', 'td_client': 'Client', 'td_km': 'Car mileage',
    'td_desc': 'Description', 'td_del_title': 'Delete transaction',
    'td_del_msg': 'Are you sure you want to delete this transaction? This cannot be undone.',
    'td_not_found': 'Transaction not found', 'td_profile_fail': 'Could not load profile',
    'vc_tap': 'Tap the microphone and dictate your trip',
    'vc_example': 'E.g.: "trip from Sants to la Sagrera for 18 euros by card for Movitaxi"',
    'vc_recording': 'Recording… tap to finish', 'vc_transcribing': 'Transcribing…',
    'vc_no_perm': 'No microphone permission', 'vc_start_fail': 'Could not start recording',
    'vc_no_audio': 'No audio recorded', 'vc_transcribe_err': 'Transcription error',
    'vc_mock': 'Sample transcription (set up OpenAI for real voice)',
    'od_summary': 'Fleet summary', 'od_export': 'Export',
    'od_export_excel': 'Export Excel', 'od_export_pdf': 'Export PDF',
    'od_generating': 'Generating {fmt} report…', 'od_generated': 'Report generated',
    'od_billing': 'Your subscription is not active. Update your payment method to keep using TaxiCount.',
    'od_search': 'Search by company (e.g. Gitaxi)', 'od_today': 'Today', 'od_custom': 'Custom',
    'od_driver': 'Driver', 'od_vehicle': 'Vehicle', 'od_kpi_income': 'Income',
    'od_kpi_expense': 'Expenses', 'od_kpi_balance': 'Balance', 'od_transactions': 'Transactions',
    'od_no_tx': 'No transactions for this filter.', 'od_expenses_chart': 'Expenses by category',
    'od_no_expenses': 'No expenses in this period.', 'od_new_record': 'New record from {name}',
    'vh_add': 'Add', 'vh_new': 'New vehicle', 'vh_plate': 'Plate', 'vh_model': 'Model',
    'vh_empty': 'No vehicles. Add the first one.', 'vh_no_model': 'No model',
    'vh_drivers_of': 'Drivers of {plate}', 'vh_no_drivers': 'No drivers. Invite one first.',
    'vh_assign_saved': 'Assignment saved',
    // Vehicle card + maintenance
    'vh_detail': 'Vehicle details', 'vh_km_current': 'Current km', 'vh_km_unknown': 'No km readings',
    'vh_assign_drivers': 'Assign drivers', 'vh_maintenance': 'Maintenance',
    'vh_itv': 'Roadworthiness (ITV)', 'vh_insurance': 'Insurance', 'vh_transport_card': 'Transport card',
    'vh_revisions': 'Services', 'vh_edit_maintenance': 'Edit maintenance',
    'vh_next': 'Next', 'vh_overdue': 'Overdue!', 'vh_today': 'Today',
    'vh_in_days': 'in {n} days', 'vh_ago_days': '{n} days ago', 'vh_no_data': 'No data',
    'vh_km_at_revision': 'Km at last service', 'vh_revision_interval': 'Every how many km',
    'vh_revision_next': 'Next service', 'vh_km_left': '{n} km left', 'vh_km_over': '{n} km over!',
    'vh_transport_years': 'Validity (years)', 'vh_maintenance_notes': 'Notes (faults, garage…)',
    'vh_maintenance_saved': 'Maintenance saved', 'vh_set_km_hint': "Enter the car's current km to compute the service",
    'vh_date_itv': 'Next ITV', 'vh_date_insurance': 'Insurance renewal',
    'vh_date_transport': 'Last transport-card stamp', 'vh_pick_date': 'Pick date', 'vh_clear': 'Clear',
    'dr_invite': 'Invite', 'dr_invite_title': 'Invite driver', 'dr_email': 'Email', 'dr_name': 'Name',
    'dr_empty': 'No drivers yet. Invite the first one.', 'dr_invited_title': 'Driver invited',
    'dr_invited_msg': 'Driver created.\n\nTemporary password (dev):\n{pwd}',
    'dr_vehicles_of': 'Vehicles of {name}', 'dr_no_vehicles': 'No vehicles. Add one first.',
    'ob_title': 'Welcome to TaxiCount', 'ob_lets_start': "Let's start! 🚕",
    'ob_intro': 'Set up your fleet in two steps. You can do it now or later.',
    'ob_step1': '1. Add your first vehicle', 'ob_step2': '2. Invite your first driver',
    'ob_finish': 'Finish setup',
    'sub_change_plan': 'Change plan', 'sub_choose_plan': 'Choose a plan', 'sub_no_plan': 'No plan',
    'sub_drivers_included': 'Drivers included: {n}', 'sub_unlimited': 'Unlimited',
    'sub_inactive_msg': 'Your subscription is not active. Subscribe or reactivate a plan to keep recording transactions.',
    'sub_manage_billing': 'Manage billing', 'sub_current': 'Current', 'sub_choose': 'Choose',
    'sub_plan_prefix': 'Plan', 'sub_no_browser': 'Could not open the browser',
    'st_active': 'Active', 'st_trial': 'Trial period', 'st_past_due': 'Payment due',
    'st_canceled': 'Canceled', 'st_inactive': 'Inactive',
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
    'set_change_vehicle_sub': "Tria un dels vehicles que t'ha assignat l'empresa",
    'set_edit_name': 'Edita el meu nom', 'set_name_hint': "Nom que veuràs a la teva app",
    'set_name_updated': 'Nom actualitzat', 'set_company': 'Empresa',
    'set_license': 'Núm. de llicència', 'set_soon': 'Properament',
    'set_locate_vehicle': 'Localitza vehicle', 'set_subscription_sub': 'Pla actiu i millora',
    'set_locate_sub': 'Cerca un conductor per ubicació',
    'loc_none': 'Cap conductor ha compartit la seva ubicació encara.',
    'loc_open_map': 'Mostra al mapa', 'loc_accuracy': 'precisió',
    'loc_last_conn': 'Última connexió', 'loc_now': 'ara mateix',
    'loc_min': 'fa {n} min', 'loc_hours': 'fa {n} h', 'loc_days': 'fa {n} d',
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
    'uncategorized': 'Sense categoria', 'particular': 'Particular',
    'cat_gasolina': 'Benzina', 'cat_gasoil': 'Gasoil', 'cat_taller': 'Taller',
    'cat_peaje': 'Peatge', 'cat_parking': 'Pàrquing', 'cat_lavado': 'Rentat',
    'cat_compra': 'Compra', 'cat_ingreso_tarjeta': 'Ingrés', 'cat_otros': 'Altres',
    'ti_new': 'Nova transacció', 'ti_edit': 'Edita la transacció', 'ti_review': 'Revisa la transacció',
    'ti_trip': 'Cursa', 'ti_expense': 'Despesa', 'ti_price': 'Preu', 'ti_amount': 'Import',
    'ti_datetime': 'Data i hora', 'ti_payment': 'Mètode de pagament', 'ti_card': 'Targeta', 'ti_cash': 'Efectiu',
    'ti_desc': 'Descripció (opcional)', 'ti_save': 'Desa', 'ti_save_changes': 'Desa els canvis',
    'ti_confirm_save': 'Confirma i desa', 'ti_origin': 'Origen', 'ti_destination': 'Destinació',
    'ti_km': 'Km del cotxe (opcional)', 'ti_client': 'Client / empresa',
    'ti_client_help': 'Buit = client particular', 'ti_category': 'Categoria', 'ti_vehicle': 'Vehicle',
    'ti_dictate': 'Dicta per veu', 'ti_invalid_amount': 'Introdueix un import vàlid',
    'ti_invalid_km': 'Els km han de ser un nombre enter', 'ti_trip_saved': 'Cursa desada',
    'ti_expense_saved': 'Despesa desada', 'ti_updated': 'Transacció actualitzada',
    'ti_blocked': "Operació bloquejada. Contacta amb l'administrador de la flota",
    'td_title': 'Detall', 'td_income': 'Ingrés', 'td_expense': 'Despesa', 'td_category': 'Categoria',
    'td_datetime': 'Data i hora', 'td_payment': 'Mètode de pagament', 'td_driver': 'Conductor',
    'td_vehicle': 'Vehicle', 'td_route': 'Trajecte', 'td_client': 'Client', 'td_km': 'Km del cotxe',
    'td_desc': 'Descripció', 'td_del_title': 'Elimina la transacció',
    'td_del_msg': 'Segur que vols eliminar aquesta transacció? Aquesta acció no es pot desfer.',
    'td_not_found': 'Transacció no trobada', 'td_profile_fail': 'No s’ha pogut carregar el perfil',
    'vc_tap': 'Prem el micròfon i dicta la teva cursa',
    'vc_example': 'Ex.: "cursa de Sants a la Sagrera per 18 euros amb targeta de Movitaxi"',
    'vc_recording': 'Gravant… prem per acabar', 'vc_transcribing': 'Transcrivint…',
    'vc_no_perm': 'Sense permís de micròfon', 'vc_start_fail': 'No s’ha pogut iniciar la gravació',
    'vc_no_audio': 'No s’ha gravat àudio', 'vc_transcribe_err': 'Error en transcriure',
    'vc_mock': "Transcripció d'exemple (configura OpenAI per a la veu real)",
    'od_summary': 'Resum de la flota', 'od_export': 'Exporta',
    'od_export_excel': 'Exporta Excel', 'od_export_pdf': 'Exporta PDF',
    'od_generating': 'Generant informe {fmt}…', 'od_generated': 'Informe generat',
    'od_billing': "La teva subscripció no està activa. Actualitza el mètode de pagament per seguir usant TaxiCount.",
    'od_search': 'Cerca per empresa (p. ex. Gitaxi)', 'od_today': 'Avui', 'od_custom': 'Personalitzat',
    'od_driver': 'Conductor', 'od_vehicle': 'Vehicle', 'od_kpi_income': 'Ingressos',
    'od_kpi_expense': 'Despeses', 'od_kpi_balance': 'Balanç', 'od_transactions': 'Transaccions',
    'od_no_tx': 'No hi ha transaccions per a aquest filtre.', 'od_expenses_chart': 'Despeses per categoria',
    'od_no_expenses': 'Sense despeses en aquest període.', 'od_new_record': 'Nou registre de {name}',
    'vh_add': 'Afegeix', 'vh_new': 'Nou vehicle', 'vh_plate': 'Matrícula', 'vh_model': 'Model',
    'vh_empty': 'No hi ha vehicles. Afegeix el primer.', 'vh_no_model': 'Sense model',
    'vh_drivers_of': 'Conductors de {plate}', 'vh_no_drivers': 'No hi ha conductors. Convida’n algun primer.',
    'vh_assign_saved': 'Assignació desada',
    // Fitxa del vehicle + manteniment
    'vh_detail': 'Fitxa del vehicle', 'vh_km_current': 'Km actuals', 'vh_km_unknown': 'Sense lectures de km',
    'vh_assign_drivers': 'Assigna conductors', 'vh_maintenance': 'Manteniment',
    'vh_itv': 'ITV', 'vh_insurance': 'Assegurança', 'vh_transport_card': 'Targeta de transport',
    'vh_revisions': 'Revisions', 'vh_edit_maintenance': 'Edita el manteniment',
    'vh_next': 'Pròxima', 'vh_overdue': 'Caducada!', 'vh_today': 'Avui',
    'vh_in_days': 'd’aquí a {n} dies', 'vh_ago_days': 'fa {n} dies', 'vh_no_data': 'Sense dades',
    'vh_km_at_revision': 'Km a l’última revisió', 'vh_revision_interval': 'Cada quants km',
    'vh_revision_next': 'Pròxima revisió', 'vh_km_left': 'falten {n} km', 'vh_km_over': '{n} km de més!',
    'vh_transport_years': 'Validesa (anys)', 'vh_maintenance_notes': 'Notes (avaria, taller…)',
    'vh_maintenance_saved': 'Manteniment desat', 'vh_set_km_hint': 'Posa els km actuals del cotxe per calcular la revisió',
    'vh_date_itv': 'Pròxima ITV', 'vh_date_insurance': 'Renovació de l’assegurança',
    'vh_date_transport': 'Últim visat de la targeta', 'vh_pick_date': 'Tria data', 'vh_clear': 'Treu',
    'dr_invite': 'Convida', 'dr_invite_title': 'Convida un conductor', 'dr_email': 'Correu', 'dr_name': 'Nom',
    'dr_empty': 'Encara no hi ha conductors. Convida el primer.', 'dr_invited_title': 'Conductor convidat',
    'dr_invited_msg': 'S’ha creat el conductor.\n\nContrasenya temporal (desenvolupament):\n{pwd}',
    'dr_vehicles_of': 'Vehicles de {name}', 'dr_no_vehicles': 'No hi ha vehicles. Afegeix-ne algun primer.',
    'ob_title': 'Benvingut a TaxiCount', 'ob_lets_start': 'Comencem! 🚕',
    'ob_intro': 'Configura la teva flota en dos passos. Pots fer-ho ara o més tard.',
    'ob_step1': '1. Afegeix el teu primer vehicle', 'ob_step2': '2. Convida el teu primer conductor',
    'ob_finish': 'Finalitza la configuració',
    'sub_change_plan': 'Canvia de pla', 'sub_choose_plan': 'Tria un pla', 'sub_no_plan': 'Sense pla',
    'sub_drivers_included': 'Conductors inclosos: {n}', 'sub_unlimited': 'Il·limitats',
    'sub_inactive_msg': 'La teva subscripció no està activa. Contracta o reactiva un pla per seguir registrant transaccions.',
    'sub_manage_billing': 'Gestiona la facturació', 'sub_current': 'Actual', 'sub_choose': 'Tria',
    'sub_plan_prefix': 'Pla', 'sub_no_browser': "No s'ha pogut obrir el navegador",
    'st_active': 'Activa', 'st_trial': 'Període de prova', 'st_past_due': 'Pagament pendent',
    'st_canceled': 'Cancel·lada', 'st_inactive': 'Inactiva',
  },
};
