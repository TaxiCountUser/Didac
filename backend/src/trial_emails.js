// Correos de bienvenida y fin de prueba, enviados con Resend (API HTTP, sin SDK).
//
// Por qué existen: en la app de Google Play NO se puede vender ni decir dónde pagar
// (política de Pagos de Play; el build Android lleva kStoreBuild). Fuera de la app
// sí: este correo es el que le dice al jefe/autónomo que la suscripción se hace en
// la web. Un cron diario (trial-emails.yml) llama a /api/v1/admin/cron/trial-emails:
//   welcome      -> empresa creada en los últimos 3 días (cada 5 min, ver abajo) (antes solo Google, que no recibe el
//                   correo de verificación de Supabase, que ya lleva la bienvenida).
//   trial_ending -> le quedan <= 3 días de prueba.
//   trial_ended  -> la prueba acabó hace <= 3 días (no se escribe a los antiguos).
// Cada aviso UNA vez (tabla trial_emails_sent, mig. 089). Solo al owner (jefe o
// autónomo), nunca al conductor; empresas de pago o cerradas, nunca.
//
// Env (Render): RESEND_API_KEY (obligatoria para enviar), EMAIL_FROM,
// EMAIL_REPLY_TO, WEB_URL. Sin RESEND_API_KEY el cron no envía nada.

const RESEND_URL = 'https://api.resend.com/emails';
const DAY = 86400000;

const TEXTS = {
  es: {
    welcome_subject: 'Bienvenido a TaxiCount 🚕',
    welcome_title: '¡Bienvenido a TaxiCount!',
    welcome_body: 'Ya tienes tu cuenta lista. Durante <b>15 días</b> puedes usarlo todo gratis y sin límite de conductores: registrar carreras por voz, cuadrar la caja y sacar tus informes en Excel.',
    welcome_body2: 'Cuando acabe la prueba, podrás seguir con un plan desde nuestra web. Te avisaremos unos días antes.',
    welcome_cta: 'Ver planes',
    ending_subject: 'Tu prueba de TaxiCount termina el {date}',
    ending_title: 'Te quedan {n} días de prueba',
    ending_body: 'Tu periodo de prueba gratuito termina el <b>{date}</b>. Para seguir registrando carreras sin cortes, suscríbete desde nuestra web entrando con tu misma cuenta.',
    ending_body2: 'Desde 3 € al mes por conductor. Todos tus datos se quedan guardados.',
    ending_cta: 'Suscribirme en la web',
    ended_subject: 'Tu prueba de TaxiCount ha terminado',
    ended_title: 'Tu prueba ha terminado',
    ended_body: 'Tu periodo de prueba gratuito terminó el <b>{date}</b>. Tus datos siguen guardados: en cuanto te suscribas desde nuestra web, la app se desbloquea para ti y tu flota.',
    ended_body2: 'Entra en la web con tu misma cuenta y elige plan. Después, en la app pulsa «Comprobar de nuevo».',
    ended_cta: 'Suscribirme en la web',
    footer: '¿Dudas? Responde a este correo o escríbenos desde el chat de soporte de la app. Lo leemos nosotros, Dídac y Jordi.',
  },
  ca: {
    welcome_subject: 'Benvingut a TaxiCount 🚕',
    welcome_title: 'Benvingut a TaxiCount!',
    welcome_body: 'Ja tens el compte a punt. Durant <b>15 dies</b> pots fer-ho servir tot gratis i sense límit de conductors: registrar carreres per veu, quadrar la caixa i treure els informes en Excel.',
    welcome_body2: 'Quan acabi la prova, podràs continuar amb un pla des del nostre web. T\'avisarem uns dies abans.',
    welcome_cta: 'Veure plans',
    ending_subject: 'La teva prova de TaxiCount acaba el {date}',
    ending_title: 'Et queden {n} dies de prova',
    ending_body: 'El teu període de prova gratuït acaba el <b>{date}</b>. Per continuar registrant carreres sense talls, subscriu-te des del nostre web entrant amb el mateix compte.',
    ending_body2: 'Des de 3 € al mes per conductor. Totes les teves dades queden desades.',
    ending_cta: 'Subscriure\'m al web',
    ended_subject: 'La teva prova de TaxiCount ha acabat',
    ended_title: 'La teva prova ha acabat',
    ended_body: 'El teu període de prova gratuït va acabar el <b>{date}</b>. Les teves dades continuen desades: tan bon punt et subscriguis des del nostre web, l\'app es desbloqueja per a tu i la teva flota.',
    ended_body2: 'Entra al web amb el mateix compte i tria un pla. Després, a l\'app prem «Comprovar de nou».',
    ended_cta: 'Subscriure\'m al web',
    footer: 'Dubtes? Respon aquest correu o escriu-nos des del xat de suport de l\'app. Ho llegim nosaltres, en Dídac i en Jordi.',
  },
  en: {
    welcome_subject: 'Welcome to TaxiCount 🚕',
    welcome_title: 'Welcome to TaxiCount!',
    welcome_body: 'Your account is ready. For <b>15 days</b> you can use everything for free with unlimited drivers: log rides by voice, balance your takings and export your reports to Excel.',
    welcome_body2: 'When the trial ends, you can continue with a plan from our website. We\'ll remind you a few days before.',
    welcome_cta: 'See plans',
    ending_subject: 'Your TaxiCount trial ends on {date}',
    ending_title: '{n} days of trial left',
    ending_body: 'Your free trial ends on <b>{date}</b>. To keep logging rides without interruption, subscribe on our website using the same account.',
    ending_body2: 'From €3 per driver per month. All your data stays saved.',
    ending_cta: 'Subscribe on the website',
    ended_subject: 'Your TaxiCount trial has ended',
    ended_title: 'Your trial has ended',
    ended_body: 'Your free trial ended on <b>{date}</b>. Your data is still saved: as soon as you subscribe on our website, the app unlocks for you and your fleet.',
    ended_body2: 'Sign in on the website with the same account and choose a plan. Then tap “Check again” in the app.',
    ended_cta: 'Subscribe on the website',
    footer: 'Questions? Reply to this email or message us from the in-app support chat. We read it ourselves — Dídac and Jordi.',
  },
};

const fill = (s, args) => s.replace(/\{(\w+)\}/g, (_, k) => (args[k] ?? `{${k}}`));
const fmtDate = (iso) => {
  const d = new Date(iso);
  return `${String(d.getUTCDate()).padStart(2, '0')}/${String(d.getUTCMonth() + 1).padStart(2, '0')}/${d.getUTCFullYear()}`;
};

/** Asunto + HTML + texto plano de un correo. kind: welcome | trial_ending | trial_ended. */
export function renderTrialEmail(kind, locale, { trialEndsAt, webUrl }) {
  const t = TEXTS[locale] ?? TEXTS.es;
  const k = { welcome: 'welcome', trial_ending: 'ending', trial_ended: 'ended' }[kind];
  if (!k) throw new Error(`kind desconocido: ${kind}`);
  const daysLeft = trialEndsAt ? Math.max(1, Math.ceil((new Date(trialEndsAt) - Date.now()) / DAY)) : 0;
  const args = { date: trialEndsAt ? fmtDate(trialEndsAt) : '', n: String(daysLeft) };
  const subject = fill(t[`${k}_subject`], args);
  const title = fill(t[`${k}_title`], args);
  const body = fill(t[`${k}_body`], args);
  const body2 = fill(t[`${k}_body2`], args);
  const cta = t[`${k}_cta`];
  const html = `<!doctype html><html><body style="margin:0;background:#f5f2ec;font-family:Arial,Helvetica,sans-serif;color:#222">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f5f2ec;padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#ffffff;border-radius:14px;overflow:hidden">
<tr><td style="padding:20px 24px 14px;border-bottom:4px solid #FFC107"><img src="${webUrl}/marca.png" width="210" alt="TaxiCount" style="display:block;width:210px;height:auto"></td></tr>
<tr><td style="padding:26px 24px 8px"><h1 style="margin:0 0 14px;font-size:21px">${title}</h1>
<p style="margin:0 0 12px;font-size:15px;line-height:1.5">${body}</p>
<p style="margin:0 0 22px;font-size:15px;line-height:1.5">${body2}</p>
<a href="${webUrl}" style="display:inline-block;background:#FFC107;color:#1f1f1f;text-decoration:none;font-weight:bold;padding:13px 22px;border-radius:10px">${cta}</a>
<p style="margin:14px 0 0;font-size:12px;color:#888">${webUrl.replace(/^https?:\/\//, '')}</p></td></tr>
<tr><td style="padding:20px 24px 24px;font-size:12px;color:#888;line-height:1.5;border-top:1px solid #eee">${t.footer}</td></tr>
</table></td></tr></table></body></html>`;
  const strip = (s) => s.replace(/<[^>]+>/g, '');
  const text = `${title}\n\n${strip(body)}\n\n${strip(body2)}\n\n${cta}: ${webUrl}\n\n${strip(t.footer)}`;
  return { subject, html, text };
}

export function createTrialEmails({ supabase, log, env = process.env, fetchImpl = fetch }) {
  const apiKey = (env.RESEND_API_KEY || '').trim();
  const from = env.EMAIL_FROM || 'TaxiCount <noreply@taxicount.com>';
  const replyTo = env.EMAIL_REPLY_TO || 'auxproduccio@gmail.com';
  const webUrl = (env.WEB_URL || 'https://www.taxicount.com').replace(/\/+$/, '');
  const enabled = () => !!apiKey;

  async function sendEmail(to, { subject, html, text }) {
    const r = await fetchImpl(RESEND_URL, {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from, to: [to], reply_to: replyTo, subject, html, text }),
    });
    if (!r.ok) throw new Error(`Resend ${r.status}: ${(await r.text()).slice(0, 200)}`);
  }

  // Idioma del owner: el de su último dispositivo (device_tokens.locale); si no, es.
  async function localeFor(userId) {
    const { data } = await supabase.from('device_tokens').select('locale')
      .eq('user_id', userId).not('locale', 'is', null)
      .order('updated_at', { ascending: false }).limit(1);
    const loc = String(data?.[0]?.locale || '').slice(0, 2).toLowerCase();
    return TEXTS[loc] ? loc : 'es';
  }

  // Marca el aviso como enviado. true si es NUEVO (hay que enviarlo).
  async function claim(tenantId, kind, ref, email) {
    const { data, error } = await supabase.from('trial_emails_sent')
      .upsert({ tenant_id: tenantId, kind, ref, email },
        { onConflict: 'tenant_id,kind,ref', ignoreDuplicates: true })
      .select('tenant_id');
    if (error) throw error;
    return !!(data && data.length);
  }
  const unclaim = (tenantId, kind, ref) => supabase.from('trial_emails_sent')
    .delete().eq('tenant_id', tenantId).eq('kind', kind).eq('ref', ref);

  /** Pasada. Devuelve {email, sent, errors, details[]}. `onlyWelcome`: solo la
   *  bienvenida (la pasada rápida de cada 5 min); sin él, todo (cron diario). */
  async function run({ now = new Date(), onlyWelcome = false } = {}) {
    if (!enabled()) return { email: false, sent: 0 };
    const nowMs = now.getTime();
    const since = new Date(nowMs - 3 * DAY).toISOString();
    const until = new Date(nowMs + 3 * DAY).toISOString();
    // Candidatas: creadas hace poco (bienvenida) o con fin de prueba en ±3 días.
    let tq = supabase.from('tenants')
      .select('id, created_at, trial_ends_at, subscription_status, closed_at')
      .is('closed_at', null);
    tq = onlyWelcome
      ? tq.gte('created_at', since)
      : tq.or(`created_at.gte.${since},and(trial_ends_at.gte.${since},trial_ends_at.lte.${until})`);
    const { data: tenants, error } = await tq;
    if (error) throw error;
    let sent = 0; let errors = 0; const details = [];
    for (const t of tenants ?? []) {
      if (['active', 'past_due'].includes(t.subscription_status)) continue; // ya paga
      const { data: owner } = await supabase.from('users')
        .select('id, email, deleted_at, active').eq('tenant_id', t.id).eq('role', 'owner')
        .order('created_at', { ascending: true }).limit(1).maybeSingle();
      if (!owner?.email || owner.deleted_at || owner.active === false) continue;
      const jobs = [];
      // Bienvenida a TODO el que crea su empresa / se hace autónomo (desde la mig.
      // 096 todos pasan por la pantalla de elegir, entren con Google o con correo).
      if (t.created_at >= since) jobs.push(['welcome', '-']);
      const end = t.trial_ends_at ? new Date(t.trial_ends_at).getTime() : null;
      if (end != null && !onlyWelcome) {
        const ref = String(t.trial_ends_at).slice(0, 10);
        if (end > nowMs && end - nowMs <= 3 * DAY) jobs.push(['trial_ending', ref]);
        else if (end <= nowMs && nowMs - end <= 3 * DAY) jobs.push(['trial_ended', ref]);
      }
      if (!jobs.length) continue;
      const locale = await localeFor(owner.id);
      for (const [kind, ref] of jobs) {
        try {
          if (!(await claim(t.id, kind, ref, owner.email))) continue; // ya enviado
          try {
            await sendEmail(owner.email, renderTrialEmail(kind, locale, { trialEndsAt: t.trial_ends_at, webUrl }));
            sent++; details.push({ tenant: t.id, kind });
          } catch (e) {
            await unclaim(t.id, kind, ref); // se reintentará mañana
            throw e;
          }
        } catch (e) {
          errors++;
          log?.warn?.(`[trial-emails] ${t.id} ${kind}: ${e.message}`);
        }
      }
    }
    return { email: true, sent, errors, details };
  }

  /** Prueba: envía los 3 correos de ejemplo a `to` (no toca el registro). */
  async function sendTest(to, locale = 'es') {
    if (!enabled()) return { email: false, sent: 0 };
    const loc = TEXTS[locale] ? locale : 'es';
    const sample = new Date(Date.now() + 3 * DAY).toISOString();
    const past = new Date(Date.now() - DAY).toISOString();
    for (const [kind, end] of [['welcome', sample], ['trial_ending', sample], ['trial_ended', past]]) {
      await sendEmail(to, renderTrialEmail(kind, loc, { trialEndsAt: end, webUrl }));
    }
    return { email: true, sent: 3 };
  }

  return { run, sendTest, enabled };
}

/** Ruta del cron: POST /api/v1/admin/cron/trial-emails  body opcional {test_to, locale}.
 *  Además, cada 5 min, la BIENVENIDA (así llega a los pocos minutos de crear la
 *  empresa, no al día siguiente). Desactivable con TRIAL_WELCOME=off; no en tests. */
export function registerTrialEmailRoutes(app, { trialEmails, cronOrAdmin, markCronRun, env = process.env }) {
  if (env.TRIAL_WELCOME !== 'off' && env.NODE_ENV !== 'test') {
    const timer = setInterval(() => {
      trialEmails.run({ onlyWelcome: true }).catch((e) => app.log.warn(`[trial-emails] bienvenida: ${e.message}`));
    }, 5 * 60 * 1000);
    timer.unref?.();
    app.addHook('onClose', async () => clearInterval(timer));
  }
  app.post('/api/v1/admin/cron/trial-emails', async (request, reply) => {
    const g = await cronOrAdmin(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const { test_to: testTo, locale } = request.body ?? {};
    if (testTo) {
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(String(testTo))) return reply.code(400).send({ error: 'test_to no válido' });
      return reply.send({ ok: true, test: true, ...(await trialEmails.sendTest(String(testTo), locale)) });
    }
    const res = await trialEmails.run();
    await markCronRun('trial_emails');
    return reply.send({ ok: true, ...res });
  });
}
