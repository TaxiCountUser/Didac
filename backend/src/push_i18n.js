// i18n de las notificaciones push. Se traduce EN EL BACKEND porque el sistema
// operativo muestra la notificación con la app cerrada, usando el title/body que
// envía el servidor. El idioma del destinatario vive en device_tokens.locale
// (lo sincroniza la app al registrar el token). Fallback: 'es'.
// {x} = argumento a rellenar. `kindKey` traduce la etiqueta de mantenimiento.

const KINDS = {
  itv: { es: 'ITV', ca: 'ITV', en: 'MOT' },
  taximeter_itv: { es: 'ITV del taxímetro', ca: 'ITV del taxímetre', en: 'taximeter inspection' },
  insurance: { es: 'seguro', ca: 'assegurança', en: 'insurance' },
  transport_card: { es: 'tarjeta de transporte', ca: 'targeta de transport', en: 'transport card' },
};

const PUSH = {
  error_report_admin: {
    es: { title: '🐞 Nuevo informe de error', body: '{reporter}: {preview}' },
    ca: { title: '🐞 Nou informe d\'error', body: '{reporter}: {preview}' },
    en: { title: '🐞 New error report', body: '{reporter}: {preview}' },
  },
  error_report_sent: {
    es: { title: 'Informe de error enviado', body: '{reporter} ha reportado un problema. El equipo de TaxiCount lo revisará.' },
    ca: { title: 'Informe d\'error enviat', body: '{reporter} ha reportat un problema. L\'equip de TaxiCount el revisarà.' },
    en: { title: 'Error report sent', body: '{reporter} reported a problem. The TaxiCount team will review it.' },
  },
  error_resolved: {
    es: { title: '✅ Informe resuelto', body: 'El problema que reportaste ha sido resuelto. ¡Gracias por avisar!' },
    ca: { title: '✅ Informe resolt', body: 'El problema que vas reportar s\'ha resolt. Gràcies per avisar!' },
    en: { title: '✅ Report resolved', body: 'The problem you reported has been resolved. Thanks for letting us know!' },
  },
  support_response: {
    es: { title: 'Respuesta de soporte', body: '{text}' },
    ca: { title: 'Resposta de suport', body: '{text}' },
    en: { title: 'Support reply', body: '{text}' },
  },
  maint_expired: {
    es: { title: '⚠️ Mantenimiento caducado', body: '{label}: {kind} venció el {date}. Conviene renovarlo.' },
    ca: { title: '⚠️ Manteniment caducat', body: '{label}: {kind} va vèncer el {date}. Convé renovar-ho.' },
    en: { title: '⚠️ Maintenance overdue', body: '{label}: {kind} expired on {date}. Renew it soon.' },
  },
  maint_today: {
    es: { title: '⏰ Mantenimiento: vence hoy', body: '{label}: {kind} vence hoy ({date}).' },
    ca: { title: '⏰ Manteniment: venç avui', body: '{label}: {kind} venç avui ({date}).' },
    en: { title: '⏰ Maintenance: due today', body: '{label}: {kind} is due today ({date}).' },
  },
  maint_soon: {
    es: { title: '⏰ Mantenimiento próximo', body: '{label}: {kind} vence en {days} día(s) ({date}).' },
    ca: { title: '⏰ Manteniment proper', body: '{label}: {kind} venç en {days} dia/es ({date}).' },
    en: { title: '⏰ Maintenance soon', body: '{label}: {kind} due in {days} day(s) ({date}).' },
  },
  maint_revision_soon: {
    es: { title: '🔧 Revisión de mantenimiento', body: '{label}: faltan ~{km} km para la próxima revisión (a los {target} km).' },
    ca: { title: '🔧 Revisió de manteniment', body: '{label}: falten ~{km} km per a la propera revisió (als {target} km).' },
    en: { title: '🔧 Maintenance service', body: '{label}: ~{km} km left until next service (at {target} km).' },
  },
  maint_revision_due: {
    es: { title: '🔧 Revisión de mantenimiento', body: '{label}: toca revisión (has superado los {target} km).' },
    ca: { title: '🔧 Revisió de manteniment', body: '{label}: toca revisió (has superat els {target} km).' },
    en: { title: '🔧 Maintenance service', body: '{label}: service due (you passed {target} km).' },
  },
  chat_from: {
    es: { title: 'Mensaje de {name}', body: '{text}' },
    ca: { title: 'Missatge de {name}', body: '{text}' },
    en: { title: 'Message from {name}', body: '{text}' },
  },
  chat_from_boss: {
    es: { title: 'Mensaje de tu jefe', body: '{text}' },
    ca: { title: 'Missatge del teu cap', body: '{text}' },
    en: { title: 'Message from your boss', body: '{text}' },
  },
  chat_from_driver: {
    es: { title: 'Mensaje de un conductor', body: '{text}' },
    ca: { title: 'Missatge d\'un conductor', body: '{text}' },
    en: { title: 'Message from a driver', body: '{text}' },
  },
  referral_discount: {
    es: { title: '🎉 ¡Has ganado un descuento!', body: 'Hito {level} conseguido: {eur}€ de descuento en tu próxima factura. ¡Sigue invitando!' },
    ca: { title: '🎉 Has guanyat un descompte!', body: 'Fita {level} aconseguida: {eur}€ de descompte a la teva propera factura. Continua convidant!' },
    en: { title: '🎉 You earned a discount!', body: 'Milestone {level} reached: {eur}€ off your next invoice. Keep inviting!' },
  },
  referral_validated: {
    es: { title: '🎉 ¡Invitación validada!', body: 'Tu invitado sigue de alta tras 15 días. Revisa tu descuento por referidos.' },
    ca: { title: '🎉 Invitació validada!', body: 'El teu convidat segueix d\'alta després de 15 dies. Revisa el teu descompte per referits.' },
    en: { title: '🎉 Referral validated!', body: 'Your invitee is still active after 15 days. Check your referral discount.' },
  },
};

// Traduce una notificación al idioma `locale`, rellenando {args}. Devuelve
// { title, body }. Si `args.kindKey` está, resuelve la etiqueta de mantenimiento.
export function pushText(locale, key, args = {}) {
  const loc = ['es', 'en', 'ca'].includes(locale) ? locale : 'es';
  const entry = PUSH[key];
  if (!entry) return { title: 'TaxiCount', body: '' };
  const t = entry[loc] || entry.es;
  const a = { ...args };
  if (a.kindKey && KINDS[a.kindKey]) a.kind = KINDS[a.kindKey][loc] || KINDS[a.kindKey].es;
  const fill = (s) => String(s ?? '').replace(/\{(\w+)\}/g, (_, k) => (a[k] != null ? String(a[k]) : ''));
  return { title: fill(t.title), body: fill(t.body) };
}
