# TaxiCount — guia de treball (estalvi de tokens)

## Regla d'or: NO llegir fitxers grossos sencers
Aquests fitxers cremen molts tokens si es llegeixen sencers — sempre **`Grep` l'àncora → `Read` amb `offset`/`limit`** només el tros:
- `backend/src/server.js` — 5.5k línies / 277 KB (monòlit, ~99 endpoints)
- `frontend/lib/l10n/app_localizations.dart` — 3.3k línies / 181 KB (mapa i18n)
- `graphify-out/graph.json` — 1,8 MB → **mai** `Read`; consulta'l amb el CLI (sota)

## Orientar-se sense obrir fitxers: graphify
El graf del projecte viu a `graphify-out/`. En lloc d'obrir fitxers per entendre l'arquitectura:
- `python -m graphify explain "nom_node"` — node + veïns en llenguatge pla
- `python -m graphify path "A" "B"` — camí més curt entre dos nodes
- Intèrpret: `graphify-out/.graphify_python` (té BOM; treu-lo). Cost en tokens ≈ 0.

## Després de CADA canvi de codi (obligatori)
1. Validar: `flutter analyze lib/` i/o `node --check backend/src/server.js`
2. Actualitzar `informe-app.md` (doc viu únic a la raíz)
3. Commit + push (backend→Render, web→Pages es despleguen sols)
4. Actualitzar el graf: `python -m graphify update .` (AST, **sense LLM**, cost ~0)
- APK: **NOMÉS quan l'usuari ho demani explícitament**. No fer builds per iniciativa.

## Backend — `backend/src/`
Mòduls germans ja extrets (llegeix-los directes, són petits): `billing.js` (webhook Stripe / `handleStripeEvent`), `parser.js`, `llm_parser.js`, `push.js`, `push_i18n.js` (traduccions de les push, es/en/ca), `reports.js`, `importer.js`, `corrections.js`.
Dins `server.js`, salta al domini fent `Grep` d'aquestes àncores de comentari (estables; les línies deriven):
| Domini | Àncora `grep` |
|---|---|
| Login per usuari | `Login con NOMBRE DE USUARIO` |
| Conductors (alta/edit/baixa) | `Invitar conductor` · `Editar conductor` · `Dar de baja` |
| Bloc admin (tot) | `SIEMPRE verifica que el llamante es admin` |
| Ingressos reals / MRR | `Ingresos REALES cobrados` · `MRR REAL` |
| Panell admin (overview) | `Panel rediseñado` |
| Mètriques plataforma | `Pols diari` |
| Tancar / reactivar empresa | `CIERRE LÓGICO de una empresa` · `REACTIVAR una empresa` |
| Seients (comprar / reduir) | `AMPLIAR: cobrar YA` · `REDUCIR: el sobrante` |
| Stripe Checkout / cupó | `Stripe Checkout` · `promotion code activo real` |
| Stripe Customer Portal | `Stripe Customer Portal` |
| Reptes | `INCREMENTAL: el progreso` |
| Referits | `Solo invitan owners` |
| Push (localitzada) | `notifyUsers` · `logSecurityEvent` (events seguretat) |
| Recompenses (crèdit Stripe) | `seatBaseRate` · `applyRewardCredit` · `test-rewards` |
| Logs de seguretat (capa B) | `logSecurityEvent` · `/admin/security/events` |
| Informes Excel/PDF · Import | `Informes Excel` · `Importar Excel/CSV` |

## Frontend — `frontend/lib/`
- **i18n**: `app_localizations.dart` és un mapa `_values` (es/en/ca). NO el llegeixis sencer — `Grep` la clau (p.ex. `adm_coup_edit`) i edita el bloc. Ús: `context.l10n.t('key',{args})`. Apòstrofs catalans escapats `\'`.
- **Kit UI admin**: `screens/admin_theme.dart` (`AdminColors`, `adminAppBar`, `adminRowsCard`, `adminSectionTitle`, `AdminKpiTile`, `AdminPill`…). Reutilitza'l, no reinventis estils.
- **Mòduls admin**: `AdminModuleScreen(module: 0..5)` = 0 Suport · 1 Retos · 2 Referits · 3 Monitorització · 4 Config · 5 Auditoria (amb sub-pestanya **Logs** = events de seguretat). Empreses i Facturació són pantalles pròpies.
- **Dades**: `services/data_service.dart` (`DataService` + `FutureBuilder`; no Provider/Riverpod).

## Estil de codi
- **NO** executar `dart format` als fitxers del repo: reflowa tot (l'estil és dens, 2 espais). Escriu amb l'estil existent i valida amb `flutter analyze lib/`.
