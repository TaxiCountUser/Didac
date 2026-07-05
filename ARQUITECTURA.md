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
- **Backend:** Node.js + **Fastify** (un únic `server.js` de ~3.500 línies) + mòduls auxiliars.
- **Base de dades / Auth:** Supabase (Postgres amb **RLS**, GoTrue JWT, funcions
  `SECURITY DEFINER`), 60 migracions SQL.
- **Pagaments:** Stripe (subscripcions, webhooks, portal de facturació).
- **IA:** OpenAI/Groq Whisper (transcripció de veu) + parser LLM opcional + parser determinista.
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
`LoginScreen` (sense sessió) · `ChangePasswordScreen` (`must_change_password`) ·
`LegalAcceptScreen` (termes/privacitat) · `TutorialScreen` · `ChoosePathScreen`
(flota o autònom) · `NoFleetScreen` (sense empresa) · `SubscriptionGateScreen`
(contractar/renovar) · `MaintenanceBanner` (mode manteniment global).

---

## 3. Funcionalitats del CONDUCTOR (Driver)

1. **Registre de transaccions** (`transaction_input_screen.dart`): import gran,
   chips de categoria, toggle ingrés/despesa, mètode de pagament, descripció.
2. **Entrada per veu** (`voice_input_screen.dart`): grava àudio → backend
   `POST /api/v1/transcribe` (Whisper) → parser determinista (`parser.js`, 55/55 =
   100%) + parser LLM opcional (`llm_parser.js`, millor en català) → preview editable
   → confirma. Caché per usuari, límit diari (150) i timeout amb reintent.
3. **Historial** (`driver_transactions_screen.dart`): llista paginada, selector
   mes/any, detall/edició/esborrat de les pròpies (protegit per RLS).
4. **Reptes propis** (`driver_challenges_screen.dart`): reptes de km/ingressos i progrés.
5. **Suport / incidències** (`incidents_screen.dart` + `incident_chat_screen.dart`):
   xat amb l'admin de plataforma.
6. **Informar d'un error** (`error-reports`): report tècnic a l'equip.
7. **Configuració** (`settings_screen.dart`): nom d'usuari visible, contrasenya, idioma.

## 4. Funcionalitats del OWNER (jefe de flota)

1. **Dashboard de flota** (`owner_dashboard_screen.dart`): KPIs
   (ingressos/despeses/balanç), gràfic de despeses per categoria (`fl_chart`), llista
   de tota la flota, filtres combinables (període, conductor, vehicle) i **temps real**
   (`supabase.channel`, un INSERT apareix a l'instant amb SnackBar).
2. **Gestió de conductors** (`drivers_screen.dart`): invitar (`POST /api/v1/drivers`,
   verifica el límit del pla), editar, eliminar.
3. **Gestió de vehicles** (`vehicles_screen.dart` + `vehicle_detail_screen.dart`):
   alta/edició/baixa (soft-delete), matrícula (taula separada, visible només per
   l'owner), quilometratge inicial, ITV/taxímetre.
4. **Exportació d'informes** (`reports.js`): Excel (`exceljs`, pestanya per conductor +
   consolidat) i PDF (`pdfmake`), respectant els filtres.
5. **Subscripció** (`subscription_screen.dart`): pla actual, canvi de pla, portal
   Stripe, i **targetes de dies gratis** (reptes + referits).
6. **Reptes** i **Referits** (secció 6).
7. **Suport** i **configuració** com el conductor.

## 5. Model de negoci: Subscripció Stripe

- **Plans** (Price IDs per entorn): Starter (≤2 conductors), Pro (≤10), Business
  (il·limitat); model per **seient** (seat).
- **Checkout:** `POST /api/v1/create-checkout-session`. **Portal:** `POST /api/v1/create-portal-session`.
- **Webhook** `POST /webhooks/stripe`: verifica la firma sobre el `rawBody`, processa
  `checkout.session.completed`, `customer.subscription.updated|deleted`,
  `invoice.paid|payment_failed` (`billing.js` → `applyStripeEvent`).
- **Període de prova:** els tenants neixen en `trialing`; `trial_ends_at` controla els dies.
- **Bloqueig per impagament:** les polítiques RLS d'escriptura de `transactions`
  exigeixen subscripció activa. La **lectura** mai es bloqueja.
- **Sincronització d'asients:** els items de la subscripció Stripe se sincronitzen amb
  el nombre de conductors.

## 6. Gamificació i creixement

### Reptes (`challenges`)
- Reptes de **km**, **dies actius** i **ingressos**, configurables des del panell
  d'admin (base + nivells + multiplicador + cicle).
- **Recompensa = mes gratis** (extensió de la subscripció, +30 dies via
  `extendTenantTrial`), **per al conductor que assoleix el repte** (el seu seient).
  NO és crèdit de Stripe.
- **Regla:** la recompensa **NO s'atorga durant el període de prova** — queda diferida
  (`deferred`) fins que el tenant paga; el cron la reintenta
  (`applyPendingChallengeCredits()` + `tenantIsPaying()`).

### Referits ("Invita y Gana", `referral_screen.dart`)
- Programa per **hitos/milestones**: segons el nombre d'empreses/autònoms convidats,
  el referenciador guanya **dies gratis** a la subscripció de **tota la seva empresa**.
- **Porta de validació de 15 dies:** el convidat ha de pagar i mantenir la subscripció
  15 dies; si no la cancel·la, aleshores el referenciador rep els dies
  (`processReferralValidationQueue()` cron + `recomputeReferrerMilestones()`, només si paga).
- Endpoints: `/referrals/code`, `/share`, `/validate`, `/progress`, `/history`.

## 7. Panell d'ADMIN de plataforma (redisseny "N" — dark/elèctric)

Tema fosc `AdminColors` + `adminDarkTheme()`, diàlegs forçats a fosc
(`showAdminDialog`), i wrapper d'amplada màxima `adminConstrained` (720px, centrat)
per a PC/web. Portada amb amplada limitada, semàfors en píndoles, targetes de mòdul
equilibrades (icona a dalt, text a baix) i KPIs 2×2 d'alçada fixa.

Mòduls:
- **Portada** (`admin_home_screen.dart`): centre de control (anell de salut + 4 KPIs),
  safata de feina (pendents de tots els mòduls amb acció directa), mòduls en targetes,
  i la **fila de semàfors** (secció 8).
- **Empreses** (`admin_companies_screen.dart` + `admin_company_detail_screen.dart`):
  llista amb **buscador global** (empresa/email/matrícula) i filtres
  (totes/pagant/prova/risc); fitxa per editar prova, conductors i vehicles.
- **Facturació** (`admin_billing_screen.dart`): MRR, ARPU, churn, cancel·lats,
  impagats, proves, i **dies gratis repartits** (reptes + referits).
- **Reptes**: config editable de tots els reptes/nivells, KPIs (completats aquest mes,
  tasa de frau), **evolució diària** (gràfic de 30 barres).
- **Referits** (`admin_referrals_tab.dart`): funnel (pendents/vàlids/rebutjats).
- **Seguretat/Auditoria** (`admin_security_tab.dart`): 3 pestanyes — **Alertes de frau**,
  **Auditoria** (log d'accions admin amb noms clars `aud_*`) i **Semàfors** (secció 8).
- **Suport** (`tickets_screen.dart` + `admin_incident_chat_screen.dart`): xat de tickets.
- **Errors** (`admin/error-reports`): reports tècnics dels usuaris.
- **Config** (`admin_config_tab.dart`): editar reptes/nivells + config general +
  **mode de manteniment** (banner a tota l'app). Els canvis s'apliquen **en calent**
  (llegits a `system_config` a cada operació).

## 8. Monitorització i semàfors del dashboard

El panell d'admin vigila **9 senyals** de salut, tots derivats de `system_config` o de
sondes en viu. Es mostren a la **portada** (fila de píndoles: punt de color + etiqueta)
i, amb detall i marca de temps, a la pestanya **Semàfors** d'Auditoria
(`GET /api/v1/admin/semaphores`).

| Semàfor | Font | 🟢 Verd | 🟡 Àmbar | 🔴 Vermell |
|---|---|---|---|---|
| **API** | backend viu | sempre (si carrega) | — | — |
| **BD (Supabase)** | `probeDb()` latència | <800 ms | ≥800 ms (lent) | la sonda falla |
| **CRONS** | `cron_last_*` | executats <48h | — | >48h |
| **BACKUP** | `cron_last_backup` | backup <48h | — | >48h / mai |
| **STRIPE** | webhook `/webhooks/stripe` | firma verificada | — | firma invàlida (secret dolent) |
| **WHISPER** | `/transcribe` | última crida OK | — | última crida va fallar |
| **OPENAI** | `parseSmart`→`llmParse` | última crida OK | — | última crida va fallar |
| **PUSH (FCM)** | `sendToTokens` | última crida OK | — | credencials/FCM fallen |
| **Purga retenció** | `cron_last_purge_retention` | informatiu (log) | — | — |

**Mecanismes:**
- `markCronRun(name)` → escriu `cron_last_<name>` (crons + backup). Semàntica de
  **frescor**: vermell si fa >48h (o mai). El backup avisa via
  `POST /api/v1/admin/cron/backup-done` des del workflow.
- `markService(name, ok)` → escriu `svc_<name>` = `ok|<iso>` o `err|<iso>`
  (whisper/openai/stripe/push). *Fire-and-forget*. Semàntica de **darrer resultat**:
  verd per defecte, vermell **només si l'última crida real va fallar** (la inactivitat
  no dona fals vermell).
- `probeDb()` → sonda de latència de Supabase en viu (a `/overview` i `/semaphores`);
  detecta **degradació** abans de la caiguda total.

## 9. Crons (schedulers externs, autenticats amb `x-cron-secret`)
- `POST /api/v1/admin/cron/apply-challenge-credits` — aplica recompenses de reptes diferides.
- `POST /api/v1/admin/cron/process-referral-validations` — processa la cua de validació
  de referits (15 dies).
- `POST /api/v1/admin/cron/backup-done` — marca el backup diari com a fet (el crida el workflow).
- `POST /api/v1/admin/cron/purge-retention` — purga fiscal: elimina definitivament les
  empreses **tancades fa >5 anys** (RPC `purge_expired_retention`, mig. 044). Compleix el
  dret a l'oblit del RGPD sense infringir la retenció fiscal. No està programat (anual).

Workflows: `cron-rewards.yml` (recompenses, diari 03:00 UTC), `backup-db.yml` (backup
diari 01:00 UTC + ping al backend), `deploy-web.yml` (GitHub Pages a cada push),
`build-apk.yml` (APK/AAB manual, versió automàtica + Release + `version.json`),
`ci.yml` (lint/test).

## 10. Seguretat i compliment
- **RLS estricta** per `tenant_id`; helpers `SECURITY DEFINER` (`current_tenant_id()`,
  `current_role_name()`) per evitar recursió.
- **service_role mai al codi d'app** (només backend); mai claus secretes de Stripe al codi.
- Defensa en profunditat: hook `preHandler` que exigeix admin a TOTA ruta `/admin/*`.
- Auditoria OWASP sense HIGH/CRITICAL (Fastify 5); Sentry guardat per DSN.
- **Retenció fiscal 5 anys** (mig. 044), acceptació legal (043), lockdown de columnes de
  `users` (040 — fix d'escalada de privilegis), `admin_actions_log` per a auditoria.
- Admin de plataforma **independent de l'empresa** (esborrar la teva empresa no esborra
  el teu compte admin).

## 11. Stack tècnic (dependències clau)
- **Backend:** `fastify`, `@supabase/supabase-js`, `stripe`, `openai`, `exceljs`,
  `pdfmake`, `firebase-admin` (push FCM), `@sentry/node`.
- **Frontend:** `supabase_flutter`, `http`, `record` (veu), `fl_chart`, `geolocator`,
  `image_picker`/`file_picker`, `firebase_messaging`, `google_sign_in`, `share_plus`,
  `url_launcher`, `package_info_plus` (avís d'actualització).
- **i18n:** sistema propi (`app_localizations.dart`) amb es/en/ca via
  `context.l10n.t('key', {args})` (fallback a la clau si falta).

## 12. Tests
- **CI (`npm run test:ci`):** unitaris purs sense Docker — `health`, parser (76/76 =
  100%), `importer`, `billing_logic` (lògica de webhook sense BD). Sempre verd al CI.
- **Integració (`npm test`):** requereix el stack local (Docker: db + kong :54321) —
  `webhook`, `billing_endpoints`, `excel`, `pdf`. Sense Docker **s'ometen netament**
  (helper `tests/unit/_stack.js`, sonda + skip amb exit 0) en comptes de fallar.
- **Flutter:** widget tests + integració (Dart pur headless per seguretat RLS, voz,
  dashboard, subscripció, reports, e2e).

## 13. Infraestructura i desplegament
- **Web:** GitHub Actions → GitHub Pages (amb reintent per l'error transitori de Pages).
- **Backend:** Render (`taxicount-backend.onrender.com`).
- **BD:** Supabase Cloud + scripts de backup (`backup-db.ps1`) i disaster recovery.
- **Mòbil:** APK signat (keystore `taxicount-upload.jks`) + Play Store via GitHub
  Actions; avís d'actualització in-app via GitHub Releases (`update_service.dart`).
- **Cost estimat:** ~88 €/mes.

## 14. Base de dades: configuració i esquema

### 14.1 Configuració (stack Supabase)
Definida a `docker-compose.yml` (dev) i replicada a **Supabase Cloud** (prod) via les 60 migracions.

| Component | Imatge / detall | Port | Funció |
|---|---|---|---|
| **Postgres** | `supabase/postgres:15.1.0.147` | 5432 (127.0.0.1) | motor + RLS + RPCs |
| **GoTrue (Auth)** | `v2.151.0` | 9999 (intern) | JWT HS256, exp 3600s, autoconfirm en dev; `service_role` = rol admin |
| **PostgREST** | — | intern | API REST sobre Postgres, respecta RLS amb el JWT |
| **Kong (Gateway)** | `2.8.1` | 54321 | exposa `/auth/v1` i `/rest/v1`; plugins cors/key-auth/acl |
| **Realtime** | `v2.30.34` (perfil opcional) | — | publica `transactions` a `supabase_realtime` |

**Xifres de l'esquema:** 60 migracions · **27 taules** · **~24 RPC** `public.*` · **53 polítiques RLS** · 2 triggers.

**Disseny de claus foranes:** totes les taules de negoci porten `tenant_id` amb
`ON DELETE CASCADE` (o `SET NULL` per a l'admin i per a `user_id`/`vehicle_id` en
`transactions`, per conservar l'històric) i `ON UPDATE CASCADE` (permet re-mapejar
l'id del perfil a l'id real d'`auth.users`).

### 14.2 Model de dades (27 taules per domini)

**Núcleo multi-tenant:**
- `tenants` — empresa. Base: `id, name`. Estès: `subscription_status, trial_ends_at,
  plan_id, drivers_limit, stripe_customer_id, stripe_subscription_id, solo, join_code, closed_at`.
- `users` — perfil (mirall d'`auth.users`). `tenant_id` (FK, **`ON DELETE SET NULL`**
  des de mig. 053 perquè l'admin sobrevisqui a l'esborrat de la seva empresa), `email,
  role (owner/driver), name, username, is_admin, active, has_completed_onboarding,
  must_change_password, legal_accepted_version, referral_code, avatar_url`.
- `vehicles` (`license_plate, model`, soft-delete) · `vehicle_licenses` (llicència
  separada, visible només per l'owner) · `driver_vehicles` (assignació conductor↔vehicle).
- `transactions` — el registre econòmic: `tenant_id, user_id, vehicle_id, amount,
  type (income/expense), category, payment_method, description, origin, destination,
  odometer_km, client_name, hidden`.

**Jornada i lectures:** `odometer_readings` · `driver_locations` · `app_usage_days` (dies actius per a reptes).

**Facturació i gamificació:** `subscription_extensions` (dies/mes gratis atorgats) ·
`challenge_claims` (reptes assolits) · `monthly_savings` i `fleet_quarterly_metrics` (històric/obsolet Loop#4).

**Referits:** `referrals` · `referral_codes` · `referral_shares` ·
`referral_milestone_rewards` · `referral_validation_queue` (cua dels 15 dies) · `referral_fraud_alerts`.

**Suport i moderació:** `incidents` · `incident_messages` · `error_reports` · `fraud_alerts`.

**Plataforma / infra:** `system_config` (config en calent + estat dels semàfors
`cron_last_*` i `svc_*`) · `admin_actions_log` (auditoria) · `cron_execution_logs` · `device_tokens` (FCM).

### 14.3 Seguretat a la BD (RLS + RPCs)
- **53 polítiques RLS:** aïllament estricte per `tenant_id`; el driver només veu les
  seves `transactions`, l'owner tota la flota; els drivers **no** llegeixen `vehicles`;
  l'escriptura de `transactions` exigeix subscripció activa.
- **Helpers `SECURITY DEFINER`** (eviten la recursió a les polítiques):
  `current_tenant_id()`, `current_role_name()`, `is_platform_admin()`, `current_subscription_active()`.
- **RPCs de negoci** (24): `create_owner_company`, `create_solo_company`,
  `join_fleet_with_code`, `set_solo_mode`, `accept_legal`, `mark_password_changed`,
  `owner_set_driver_name`, `set_vehicle_license`, `generate_referral_code` /
  `set_referral_code` / `set_my_referrer`, `challenge_stats` / `challenge_stats_tenant`,
  `email_for_username` (login per nom d'usuari), `purge_expired_retention` (purga fiscal),
  `cleanup_old_incidents`.
- **Trigger clau:** `handle_new_auth_user` sobre `auth.users` — un owner nou crea el seu
  tenant; un driver amb `tenant_id` a la metadata s'uneix a la flota. És el pont entre
  l'autenticació (GoTrue) i el model de dades (`public.users`).

---

## Resum en una línia
TaxiCount és un SaaS multi-tenant complet per a flotes de taxi: registre econòmic manual
i per veu, dashboards en temps real, informes fiscals, subscripció Stripe amb prova,
gamificació (reptes → mes gratis per conductor) i referits (→ dies gratis per a tota
l'empresa, amb validació de 15 dies), tot sobre Flutter + Fastify + Supabase, amb un
panell d'admin de plataforma redissenyat, separat i amb 9 semàfors de monitorització.
