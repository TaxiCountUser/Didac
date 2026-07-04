# TaxiCount — Informe complet d'arquitectura i funcionalitats

> Document viu. Última actualització: 2026-07-05.

## 1. Què és TaxiCount

TaxiCount és una **plataforma SaaS B2B multi-tenant** per a la gestió econòmica de
flotes de taxi i taxistes autònoms. Cada empresa (tenant) està totalment aïllada de
la resta. Permet registrar ingressos i despeses (a mà o **per veu**), veure quadres
de comandament en temps real, exportar informes fiscals, gestionar conductors i
vehicles, i tot això sota un model de **subscripció Stripe** amb període de prova,
gamificació (reptes) i programa de referits.

- **Frontend:** Flutter (web sobre GitHub Pages + Android APK/Play Store).
- **Backend:** Node.js + **Fastify** (un únic `server.js` de ~3.435 línies) + mòduls auxiliars.
- **Base de dades / Auth:** Supabase (Postgres amb **RLS**, GoTrue JWT, funcions
  `SECURITY DEFINER`), 60 migracions SQL.
- **Pagaments:** Stripe (subscripcions, webhooks, portal de facturació).
- **IA:** OpenAI Whisper (transcripció de veu) + parser determinista.
- **Infra prod:** backend a **Render**, base de dades a **Supabase Cloud**, web a **GitHub Pages**.

---

## 2. Rols i fluxos d'accés

L'`auth_gate.dart` és el porter que decideix quina pantalla veu cada usuari.

| Rol / estat | Pantalla d'entrada | Què pot fer |
|---|---|---|
| **Admin de plataforma** | `AdminHomeScreen` | Accés EXCLUSIU al panell d'admin (didakdp.5@gmail.com i tecinfo.jordi@gmail.com). No veu cap dada d'empresa com a usuari. |
| **Owner (jefe de flota)** | `OwnerHomeScreen` | Gestiona conductors, vehicles, dashboard de tota la flota, subscripció, reptes, referits. |
| **Driver (conductor)** | `DriverHomeScreen` | Registra les seves transaccions, veu el seu historial, reptes propis, suport. |
| **Solo (autònom)** | `SoloHomeScreen` | Owner + driver a la vegada: un sol usuari gestiona el seu propi taxi. |

**Portes intermèdies** que l'`auth_gate` intercala abans d'arribar a la home:
- `LoginScreen` si no hi ha sessió.
- `ChangePasswordScreen` si `must_change_password` (conductor acabat de crear).
- `LegalAcceptScreen` per acceptar termes/privacitat (retenció legal).
- `TutorialScreen` (tutorial inicial).
- `ChoosePathScreen` (triar si ets flota o autònom).
- `NoFleetScreen` si l'usuari va quedar sense empresa.
- `SubscriptionGateScreen` si cal contractar/renovar.

---

## 3. Funcionalitats del CONDUCTOR (Driver)

1. **Registre de transaccions** (`transaction_input_screen.dart`): import gran, chips
   de categoria, toggle ingrés/despesa, mètode de pagament, descripció.
2. **Entrada per veu** (`voice_input_screen.dart`): grava àudio → backend
   `POST /api/v1/transcribe` (Whisper) → **parser determinista** (`parser.js`,
   precisió 55/55 = 100%) → pantalla de preview editable → confirma. Amb caché per
   usuari, límit diari (150) i timeout amb reintent.
3. **Historial** (`driver_transactions_screen.dart`): llista paginada (scroll
   infinit, selector mes/any), detall/edició/esborrat de les pròpies (protegit per RLS).
4. **Reptes propis** (`driver_challenges_screen.dart`): veu els seus reptes de
   km/ingressos i el progrés.
5. **Suport / incidències** (`incidents_screen.dart` + `incident_chat_screen.dart`):
   xat amb l'admin de plataforma.
6. **Informar d'un error** (`error-reports`): report tècnic a l'equip.
7. **Configuració** (`settings_screen.dart`): canvi de nom d'usuari visible, canvi de
   contrasenya, idioma.

## 4. Funcionalitats del OWNER (jefe de flota)

1. **Dashboard de flota** (`owner_dashboard_screen.dart`): KPIs
   (ingressos/despeses/balanç), gràfic de despeses per categoria (`fl_chart`), llista
   de tota la flota, filtres combinables (període Hoy/Semana/Mes/Personalitzat,
   conductor, vehicle) i **sincronització en temps real** (`supabase.channel`, un
   INSERT apareix a l'instant amb SnackBar).
2. **Gestió de conductors** (`drivers_screen.dart`): invitar (`POST /api/v1/drivers`,
   verifica el límit del pla), editar, eliminar.
3. **Gestió de vehicles** (`vehicles_screen.dart` + `vehicle_detail_screen.dart`):
   alta/edició/baixa (soft-delete), matrícula (taula separada, visible només per
   l'owner), quilometratge inicial, ITV/taxímetre.
4. **Exportació d'informes** (`reports.js`): Excel (`exceljs`, una pestanya per
   conductor + consolidat) i PDF (`pdfmake`), respectant els filtres del dashboard.
5. **Subscripció** (`subscription_screen.dart`): pla actual, canvi de pla, portal de
   facturació Stripe, i **targetes de dies gratis** (reptes + referits).
6. **Reptes** i **Referits** (veure secció 6).
7. **Suport** i **configuració** com el conductor.

## 5. Model de negoci: Subscripció Stripe

- **Plans** (Price IDs per entorn): Starter (≤2 conductors), Pro (≤10), Business (il·limitat).
- **Checkout:** `POST /api/v1/create-checkout-session`. **Portal:** `POST /api/v1/create-portal-session`.
- **Webhook** `POST /webhooks/stripe`: verifica la firma sobre el `rawBody`, processa
  `checkout.session.completed`, `customer.subscription.updated|deleted`,
  `invoice.paid|payment_failed`.
- **Període de prova:** els tenants neixen en `trialing`; `trial_ends_at` controla els
  dies restants.
- **Bloqueig per impagament:** les polítiques RLS d'escriptura de `transactions`
  exigeixen subscripció activa. Si no, el conductor veu "Operació bloquejada" i l'owner
  un banner. La **lectura** mai es bloqueja.
- **Sincronització d'asients:** el nombre d'items de la subscripció Stripe es
  sincronitza amb el nombre de conductors.

## 6. Gamificació i creixement

### Reptes (`challenges`)
- Reptes de **km**, **dies actius** i **ingressos**, configurables des del panell
  d'admin (base + nivells + multiplicador + cicle).
- **Recompensa = mes gratis** (extensió de la subscripció, +30 dies via
  `extendTenantTrial`), **NO crèdit de Stripe**.
- **Regla clau:** la recompensa **NO s'atorga durant el període de prova** — queda
  diferida (`deferred`) fins que el tenant paga; el cron la reintenta. Gestionat per
  `applyPendingChallengeCredits()` amb la garantia `tenantIsPaying()`.

### Referits ("Invita y Gana", `referral_screen.dart`)
- Programa per **hitos/milestones**: segons el nombre d'empreses/autònoms convidats,
  l'owner referenciador guanya **dies gratis** a la seva subscripció activa.
- **Porta de validació de 15 dies:** el convidat ha de fer el pagament i mantenir la
  subscripció 15 dies; si no la cancel·la, aleshores el referenciador rep els dies.
  Gestionat per `processReferralValidationQueue()` (cron) +
  `recomputeReferrerMilestones()` (només si el referenciador paga).
- Endpoints: `/referrals/code`, `/share`, `/validate`, `/progress`, `/history`.

## 7. Panell d'ADMIN de plataforma (redisseny "N" — dark/elèctric)

Redisseny complet (2026-07-04) amb tema fosc `AdminColors`, `adminDarkTheme()`,
diàlegs forçats a fosc (`showAdminDialog`), i wrapper d'amplada màxima
`adminConstrained` (720px, centrat) per a PC/web.

Mòduls:
- **Portada** (`admin_home_screen.dart`): centre de control amb KPIs, safata de feina
  (incidències obertes, errors) i mòduls en targetes; semàfors de salut de crons.
- **Empreses** (`admin_companies_screen.dart` + `admin_company_detail_screen.dart`):
  llista amb **buscador global** (empresa/email/matrícula, resolt al backend) i filtres
  (totes/pagant/prova/risc); fitxa per editar període de prova, conductors i vehicles.
- **Facturació** (`admin_billing_screen.dart`): MRR, ARPU, churn, cancel·lats,
  impagats, proves, i **dies gratis repartits** (reptes + referits).
- **Reptes** (mòdul dins `admin_screen.dart`): config editable de tots els reptes i
  nivells, KPIs (completats aquest mes, tasa de frau), **evolució diària** (gràfic de 30 barres).
- **Referits** (`admin_referrals_tab.dart`): funnel (pendents/vàlids/rebutjats),
  referenciadors diferents, gestió/bloqueig.
- **Seguretat/Auditoria** (`admin_security_tab.dart`): registre d'accions amb noms
  clars (`aud_*`); es registren updates de company/vehicle/user, deletes, etc.
- **Suport** (`tickets_screen.dart` + `admin_incident_chat_screen.dart`): xat de tickets redissenyat.
- **Errors** (`admin/error-reports`): reports tècnics dels usuaris.
- **Config** (`admin_config_tab.dart`): editar tots els reptes/nivells + configuracions
  generals + **mode de manteniment** (banner amber a tota l'app via
  `maintenance_banner.dart`). Els canvis s'apliquen **en calent** (llegits a
  `system_config` a cada operació).

## 8. Crons (schedulers externs, autenticats amb `x-cron-secret`)
- `POST /api/v1/admin/cron/apply-challenge-credits` — aplica recompenses de reptes diferides.
- `POST /api/v1/admin/cron/process-referral-validations` — processa la cua de validació
  de referits (15 dies).
- `POST /api/v1/admin/cron/purge-retention` — purga dades segons retenció fiscal (5 anys).

## 9. Seguretat i compliment
- **RLS estricta** per `tenant_id`; helpers `SECURITY DEFINER` (`current_tenant_id()`,
  `current_role_name()`) per evitar recursió.
- **service_role mai al codi d'app** (només backend).
- Auditoria OWASP sense HIGH/CRITICAL (Fastify 5); Sentry guardat per DSN.
- **Retenció fiscal de 5 anys** (mig. 044), acceptació legal (043), lockdown de
  columnes de `users` (040 — fix d'escalada de privilegis).
- Admin de plataforma **independent de l'empresa** (esborrar la teva empresa no esborra
  el teu compte admin).

## 10. Stack tècnic (dependències clau)
- **Backend:** `fastify`, `@supabase/supabase-js`, `stripe`, `openai`, `exceljs`,
  `pdfmake`, `firebase-admin` (push FCM), `@sentry/node`.
- **Frontend:** `supabase_flutter`, `http`, `record` (veu), `fl_chart`, `geolocator`
  (localitzar vehicle), `image_picker`/`file_picker`, `firebase_messaging`,
  `google_sign_in`, `share_plus`, `url_launcher`.
- **i18n:** sistema propi (`app_localizations.dart`) amb es/en/ca via
  `context.l10n.t('key', {args})`.

## 11. Infraestructura i desplegament
- **Web:** GitHub Actions → GitHub Pages (amb reintent per l'error transitori de Pages).
- **Backend:** Render (`taxicount-backend.onrender.com`).
- **BD:** Supabase Cloud + scripts de backup (`backup-db.ps1`) i disaster recovery.
- **Mòbil:** APK signat (keystore `taxicount-upload.jks`) + Play Store via GitHub
  Actions; avís d'actualització in-app via GitHub Releases (`update_service.dart`).
- **Cost estimat:** ~88 €/mes.

---

## Resum en una línia
TaxiCount és un SaaS multi-tenant complet per a flotes de taxi: registre econòmic
manual i per veu, dashboards en temps real, informes fiscals, subscripció Stripe amb
prova, gamificació (reptes → mes gratis) i referits (→ dies gratis, amb validació de
15 dies), tot sobre Flutter + Fastify + Supabase, amb un panell d'admin de plataforma
redissenyat i separat.
