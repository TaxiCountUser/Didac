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

## Subagents (estalvi de tokens en cerques amples)
Per a QUALSEVOL cerca ampla (localitzar codi, auditar un mòdul, traçar un flux entre
fitxers) usa un subagent: ell llegeix els bolcats grossos al **seu** context i torna
només la conclusió, sense omplir el fil principal.
- **`taxi-scout`** (`.claude/agents/taxi-scout.md`) — explorador **només-lectura** amb
  aquestes regles incrustades (graphify, grep+offset, mai fitxers grossos sencers). És el
  per defecte d'aquest repo.
- Integrats: `Explore` (cerques amples), `Plan` (dissenyar plans), `general-purpose`.

## Després de CADA canvi de codi (obligatori)
1. Validar: `flutter analyze lib/` i/o `node --check backend/src/server.js`
2. Actualitzar `informe-app.md` (doc viu únic a la raíz)
3. Commit + push (backend→Render, web→Pages es despleguen sols)
4. Actualitzar el graf: `python -m graphify update .` (AST, **sense LLM**, cost ~0)
- APK: **NOMÉS quan l'usuari ho demani explícitament**. No fer builds per iniciativa.

## Backend — `backend/src/`
Mòduls germans ja extrets (llegeix-los directes, són petits): `billing.js` (webhook Stripe / `handleStripeEvent`), `parser.js`, `llm_parser.js`, `push.js`, `push_i18n.js` (traduccions de les push, es/en/ca), `reports.js`, `importer.js`, `corrections.js`.

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
| Seients (comprar / reduir) | `AMPLIAR: cobrar YA` · `REDUCIR: el sobrante` |
| Stripe Checkout / cupó | `Stripe Checkout` · `promotion code activo real` |
| Stripe Customer Portal | `Stripe Customer Portal` |
| Reptes | `INCREMENTAL: el progreso` |
| Referits | `Solo invitan owners` · `Invita y Gana` · `Validación de referidos a 15 días` |
| Anti-frau de referits | `Anti-fraude de referidos` · `Centro de fraude` |
| Push localitzada / chat flota | `notifyUsers` · `Notificación push de una incidencia` · `chat de flota` |
| Recompenses (crèdit Stripe) | `seatBaseRate` · `applyRewardCredit` · `applyPendingChallengeCredits` · `recomputeReferrerMilestones` · `test-rewards` |
| Logs de seguretat (capa B) | `logSecurityEvent` · `/admin/security/events` |
| Semàfors / uptime | `computeSemaphores` · `markService` · `readServiceUptime` · `/cron/semaphores` |
| Informes d'error (app) | `Informes de error` |
| Informes Excel/PDF · Import | `Informes Excel` · `Importar Excel/CSV` |
| Config sistema (trial/retenció) | `default_trial_days` · `SYSTEM_KEYS` |

## Pla de troceig de `server.js` (feina PENDENT)
Detall viu a `informe-app.md §6.1`. Ordre acordat: **Fase A helpers purs** (`rewards.js`
← seatBaseRate/applyRewardCredit/…; `monitoring.js` ← computeSemaphores/markService/
readServiceUptime; `security_log.js` ← logSecurityEvent) → **Fase B rutes** (1r Retos,
2n Fraude, 3r Referits, …). `rewards.js` va abans perquè el comparteixen Retos i Referits.
Discutir abans de cada extracció; `node --check` + tests integració verds abans del commit.

## Frontend — `frontend/lib/`
- **i18n**: `app_localizations.dart` és un mapa `_values` (es/en/ca). NO el llegeixis sencer — `Grep` la clau (p.ex. `adm_coup_edit`) i edita el bloc. Ús: `context.l10n.t('key',{args})`. Apòstrofs catalans escapats `\'`.
- **Kit UI admin**: `screens/admin_theme.dart` (`AdminColors`, `adminAppBar`, `adminRowsCard`, `adminSectionTitle`, `AdminKpiTile`, `AdminPill`…). Reutilitza'l, no reinventis estils.
- **Mòduls admin**: `AdminModuleScreen(module: 0..5)` = 0 Suport · 1 Retos · 2 Referits · 3 Monitorització · 4 Config · 5 Auditoria (amb sub-pestanya **Logs** = events de seguretat). Empreses i Facturació són pantalles pròpies.
- **Dades**: `services/data_service.dart` (`DataService` + `FutureBuilder`; no Provider/Riverpod).

## Estil de codi
- **NO** executar `dart format` als fitxers del repo: reflowa tot (l'estil és dens, 2 espais). Escriu amb l'estil existent i valida amb `flutter analyze lib/`.
