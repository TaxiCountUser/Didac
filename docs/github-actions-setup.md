# GitHub Actions — secrets y variables para el despliegue

Configura esto en el repo: **Settings → Secrets and variables → Actions**.
El workflow [`deploy.yml`](../.github/workflows/deploy.yml) se dispara con tags
`v*`. Los pasos de **deploy real** están desactivados hasta que pongas las
*variables* `DEPLOY_*` a `true` (así un tag no despliega por accidente).

## Variables (pestaña "Variables")

| Variable | Valor | Efecto |
| -------- | ----- | ------ |
| `DEPLOY_VPS` | `true` | Activa el deploy del backend al VPS por SSH. |
| `DEPLOY_WEB` | `true` | Activa el deploy de Flutter Web a Vercel. |
| `BUILD_MOBILE` | `true` (opcional) | Construye el APK como artefacto del release. |

## Secrets (pestaña "Secrets")

### Backend → VPS
| Secret | Descripción |
| ------ | ----------- |
| `VPS_HOST` | IP o host del VPS. |
| `VPS_USER` | Usuario SSH. |
| `VPS_SSH_KEY` | Clave **privada** SSH (el VPS tiene la pública). |

> En el VPS, crea `/opt/taxicount/backend.env` con las variables de entorno de
> producción del backend (ver [production-setup.md](production-setup.md) §2):
> `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `OPENAI_API_KEY`,
> `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_PRICE_*`,
> `ALLOW_MOCK_TRANSCRIBE=false`, `CORS_ORIGIN=https://taxicount.app`,
> `SENTRY_DSN` (opcional).

### Web → Vercel
| Secret | Descripción |
| ------ | ----------- |
| `VERCEL_TOKEN` | Token de Vercel. |
| `VERCEL_ORG_ID` | ID de la organización. |
| `VERCEL_PROJECT_ID` | ID del proyecto. |
| `PROD_SUPABASE_URL` | URL del proyecto Supabase Cloud. |
| `PROD_SUPABASE_ANON_KEY` | anon key (pública por diseño). |
| `PROD_BACKEND_URL` | `https://api.taxicount.app`. |
| `PROD_STRIPE_PRICE_STARTER` | Price ID live del plan Starter. |
| `PROD_STRIPE_PRICE_PRO` | Price ID live del plan Pro. |
| `PROD_STRIPE_PRICE_BUSINESS` | Price ID live del plan Business. |

> La imagen del backend se publica en **GHCR** con el `GITHUB_TOKEN` integrado;
> no necesitas un secret extra para el push del contenedor.

## Verificación previa (ya realizada en local)

Antes de pushear el tag, estos pasos del pipeline se validaron en local:

- ✅ `docker build ./backend` → imagen construida y **arranca** (`/health` 200).
- ✅ `flutter build web --release` → `build/web` generado sin errores.

## Lanzar un release

```bash
git tag -a v1.0.1 -m "TaxiCount v1.0.1"
git push origin v1.0.1
```

Sigue el progreso en la pestaña **Actions** del repo.
