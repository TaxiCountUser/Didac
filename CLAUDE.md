# TaxiCount — guia de treball (estalvi de tokens)

> **Índex d'aquesta guia:** Regla d'or (fitxers grossos) · graphify · Subagents ·
> Rutina post-canvi · Backend (mapa d'àncores + closure `buildApp`) · Pla de troceig ·
> Frontend · Estil de codi · Docs vius.

## Regla d'or: NO llegir fitxers grossos sencers
Aquests fitxers cremen molts tokens si es llegeixen sencers — sempre **`Grep` l'àncora → `Read` amb `offset`/`limit`** només el tros:
- `backend/src/server.js` — ~5.9k línies / 305 KB (monòlit, 98 endpoints)
- `frontend/lib/l10n/app_localizations.dart` — 3.3k línies / 181 KB (mapa i18n)
- `graphify-out/graph.json` — 1,8 MB → **mai** `Read`; consulta'l amb el CLI (sota)
- `informe-app.md` — doc gran; té **índex al capdamunt** + mapa de navegació. Salta amb `grep -nE "^#{2,3} "`.

## Orientar-se sense obrir fitxers: graphify
El graf del projecte viu a `graphify-out/`. En lloc d'obrir fitxers per entendre l'arquitectura:
- `python -m graphify explain "nom_node"` — node + veïns en llenguatge pla
- `python -m graphify path "A" "B"` — camí més curt entre dos nodes
- Intèrpret: `graphify-out/.graphify_python` (té BOM; treu-lo). Cost en tokens ≈ 0.

## Higiene de sessió i cache (estalvi de tokens)
El cost dominant és el **context acumulat** (cada torn reenvia tot l'històric), no cap fitxer concret:
- **1 tema = 1 sessió.** `/clear` en canviar de tema (deixa anar tot el context acumulat); `/compact` quan la sessió es fa llarga.
- **Cache-aware:** editar un fitxer sempre-carregat (`CLAUDE.md`, `MEMORY.md`) al mig de la sessió invalida el *prompt cache* i cada torn següent el torna a pagar. **Agrupar les actualitzacions de docs al final de la feina** (coincideix amb la norma "en acabar la feina").
- **Filtrar sortida sorollosa:** `npm test`/`flutter test`/`flutter build` escupen logs enormes → `... 2>&1 | tail -20` o `| grep -iE "pass|fail|error"`. `node --check` i `flutter analyze` ja són petits.
- **Editar `informe-app.md` quirúrgicament:** `grep` la capçalera (té TOC) → `Read`/`Edit` la secció; mai rellegir-lo sencer.

## Subagents (estalvi de tokens en cerques amples)
Per a QUALSEVOL cerca ampla (localitzar codi, auditar un mòdul, traçar un flux entre
fitxers) usa un subagent: ell llegeix els bolcats grossos al **seu** context i torna
només la conclusió, sense omplir el fil principal.
- **`taxi-scout`** (`.claude/agents/taxi-scout.md`) — explorador **només-lectura** amb
  aquestes regles incrustades (graphify, grep+offset, mai fitxers grossos sencers). És el
  per defecte d'aquest repo.
- Integrats: `Explore` (cerques amples), `Plan` (dissenyar plans), `general-purpose`.

## En ACABAR cada feina (obligatori)
Norma: cap `.md` pot quedar desfasat. En acabar cada tasca/feature:
1. Validar: `flutter analyze lib/` i/o `node --check backend/src/server.js`
2. Actualitzar **tots els `.md` afectats** perquè no quedin desactualitzats:
   `informe-app.md` (sempre que canviï arquitectura/mòduls/esquema/deps) i **`CLAUDE.md`**
   (quan canviï el mapa d'àncores, l'estructura, els números o el frontend), més qualsevol
   `docs/…` tocat.
3. Commit + push (backend→Render, web→Pages es despleguen sols)
4. Actualitzar el graf: `python -m graphify update .` (AST, **sense LLM**, cost ~0)
- APK: **NOMÉS quan l'usuari ho demani explícitament**. No fer builds per iniciativa.

## Backend — `backend/src/`
Mòduls germans ja extrets (llegeix-los directes, són petits): `billing.js` (webhook Stripe / `handleStripeEvent`), `parser.js`, `llm_parser.js`, `push.js`, `push_i18n.js` (traduccions de les push, es/en/ca), `reports.js`, `importer.js`, `corrections.js`, `security_log.js` (`createSecurityLog({supabase,log})` → `logSecurityEvent`; Fase A #1, FET), `rewards.js` (`createRewards({stripe,supabase,log,tenantIsPaying,refConfig,milestonesFrom,notifyUser})` → seatBaseRate/applyRewardCredit/reverseRewardCredit/applyPendingChallengeCredits/freeDaysForTenant/recomputeReferrerMilestones; Fase A #2, FET), `monitoring.js` (`createMonitoring({supabase,log,probeDb})` → markService/computeSemaphores; `readServiceUptime` privat; `pushEnabled` import directe; Fase A #3, FET).

**Estructura de `server.js`:** gairebé tot (rutes + helpers) viu dins d'un únic *closure* `export async function buildApp()` (~L286), compartint `app`, `supabase`, `stripe` i les constants del capdamunt (L26–180). Les rutes es registren amb `app.get/post/put/patch/delete('/api/v1/...')`; 67 de 98 són `/api/v1/admin/*`. `async function start()` (final) arrenca el servidor. Per això extreure un domini = plugin `registerXxxRoutes(app, deps)` amb dependències injectades.

Dins `server.js`, salta al domini fent `Grep` d'aquestes àncores de comentari (estables; les línies deriven):
| Domini | Àncora `grep` |
|---|---|
| Health / rate-limit / capçaleres seg. | `--- Health ---` · `Rate limit global` · `Cabeceras de seguridad` |
| Transcripció + parseo (veu) | `Transcripción + parseo` · `parseSmart` |
| Login per usuari | `Login con NOMBRE DE USUARIO` |
| Conductors (alta/edit/baixa) | `Invitar conductor` · `Editar conductor` · `Dar de baja` |
| Bloc admin (tot) | `SIEMPRE verifica que el llamante es admin` · `adminGuard` |
| Ingressos reals / MRR / comissió | `Ingresos REALES cobrados` · `MRR REAL` · `readGlobalFees` |
| Panell admin (overview) | `Panel rediseñado` |
| Mètriques plataforma | `Pols diari` |
| Tancar / reactivar empresa | `CIERRE LÓGICO de una empresa` · `REACTIVAR una empresa` |
| Seients + Checkout/Portal + cupó | **→ `subscription.js`** (`registerSubscriptionRoutes`, 11 endpoints + tota la lògica de cupó; retorna `syncScheduledCoupon` per al cron). A server.js queden els helpers de seients `seatCount`/`setSeatQuantity`/`enforceSeatLimit` (injectats; enforceSeatLimit compartit amb billing.js) |
| Reptes | **→ `retos.js`** (`registerRetosRoutes`, 7 endpoints + helpers challengeConfig/levelState/…); a server.js queda el cron `apply-challenge-credits` i `/tenant/free-days` |
| Referits | **→ `referrals.js`** (`registerReferralsRoutes`, 15 endpoints + anti-frau `createFraudAlert`/`runFraudChecks`); a server.js queden refConfig/milestonesFrom (compartits amb rewards.js), helpers de cua/reversió (compartits amb billing.js) i el cron `process-referral-validations` |
| Centro de fraude (visor) | **→ `fraud.js`** (`registerFraudRoutes`, 3 endpoints `/admin/fraud/alerts*`) |
| Anti-frau de referits (scan/config) | **→ `referrals.js`** (`createFraudAlert`/`runFraudChecks` + endpoints `/admin/referrals/scan`) |
| Incidències + push (rutes) | **→ `incidents.js`** (`registerIncidentsRoutes`; admin/incidents + notify-incident/notify-fleet-message/boss-name) |
| Helpers push (core) | `notifyUsers`/`notifyUser`/`notifyUsersRaw` (queden a server.js, compartits; s'injecten) |
| Recompenses (crèdit Stripe) | **→ `rewards.js`** (helpers); a server.js: crides + `test-rewards` |
| Logs de seguretat (capa B) | **→ `security_log.js`** (`logSecurityEvent`); a server.js: `/admin/security/events` · `/security/auth-failed` (email/Google, reportat pel client) |
| Semàfors / uptime | **→ `monitoring.js`** (`computeSemaphores`/`markService`); a server.js: `/admin/semaphores` · `/cron/semaphores` |
| Informes d'error (app) | `Informes de error` |
| Informes Excel/PDF · Import | **→ `reports_routes.js`** (`registerReportsRoutes`; delega a `reports.js`/`importer.js`/`llm_parser.js`) |
| Config sistema (trial/retenció) | `default_trial_days` · `SYSTEM_KEYS` |

## Pla de troceig de `server.js` (Fase A FETA; Fase B EN CURS)
Detall viu a `informe-app.md §6.1`. Dos patrons: **helpers** = factory `createXxx(deps)` que
retorna closures; **rutes** = plugin `registerXxxRoutes(app, deps)` que registra rutes sobre
`app`. Tots s'instancien/criden dins `buildApp()` a dalt (després de crear app/supabase/stripe
i els helpers de rewards/monitoring; els guards adminGuard/getCaller/logAdminAction són `function`
hoisted). **Fase A COMPLETA**: ✅ `security_log.js` · ✅ `rewards.js` · ✅ `monitoring.js`.
**Fase B EN CURS**: ✅ `retos.js` (7) · ✅ `fraud.js` (3) · ✅ `referrals.js` (15 + anti-frau) · ✅ `reports_routes.js` (Excel/PDF+Import) · ✅ `incidents.js` (incidents+push) · ✅ `subscription.js` (checkout/portal/seients/cupó) · ✅ `odometer.js` (correcció km) · ✅ `audit_viewers.js` (audit/logs+security/events+client-errors) → pendent **Panel admin** (6 sub-clústers: financer/empreses/usuaris/odòmetre✅/visors✅/flags; fer per sub-clúster, el financer l'últim per diners/RGPD)…
⚠️ **LLIÇÓ Retos:** els dominis NO sempre són contigus — verificar SEMPRE amb grep dels
`app.get/post(...paths...)` dins el rang abans de tallar (Retos eren 2 zones separades per
odòmetre/frau/auditoria). Injectar constants module-level també (p.ex. `MAX_SEATS`: un test
va caçar `MAX_SEATS is not defined` que node --check NO veu). server.js: ~5.9k → ~3.45k línies. Agrupar rutes admin de cara a
go-live #4. Discutir abans de cada extracció; `node --check` + `npm test` verds abans del commit.

## Frontend — `frontend/lib/`
- **i18n**: `app_localizations.dart` és un mapa `_values` (es/en/ca). NO el llegeixis sencer — `Grep` la clau (p.ex. `adm_coup_edit`) i edita el bloc. Ús: `context.l10n.t('key',{args})`. Apòstrofs catalans escapats `\'`.
- **Kit UI admin**: `screens/admin_theme.dart` (`AdminColors`, `adminAppBar`, `adminRowsCard`, `adminSectionTitle`, `AdminKpiTile`, `AdminPill`…). Reutilitza'l, no reinventis estils.
- **Mòduls admin**: `AdminModuleScreen(module: 0..5)` = 0 Suport · 1 Retos · 2 Referits · 3 Monitorització · 4 Config · 5 Auditoria (amb sub-pestanya **Logs** = events de seguretat). Empreses i Facturació són pantalles pròpies.
- **Dades**: `services/data_service.dart` (`DataService` + `FutureBuilder`; no Provider/Riverpod).

## Estil de codi
- **NO** executar `dart format` als fitxers del repo: reflowa tot (l'estil és dens, 2 espais). Escriu amb l'estil existent i valida amb `flutter analyze lib/`.
