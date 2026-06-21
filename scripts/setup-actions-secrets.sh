#!/usr/bin/env bash
# ============================================================
# TaxiCount - Carga secrets y variables en GitHub Actions con la CLI `gh`.
#
# Requisitos:
#   1. gh instalado y autenticado:  gh auth login
#   2. Copiar scripts/.actions-secrets.env.example -> scripts/.actions-secrets.env
#      y rellenar los valores (ese fichero está gitignored).
#
# Uso:  bash scripts/setup-actions-secrets.sh
#
# Idempotente: vuelve a ejecutar cuando cambies un valor. Los campos vacíos se
# OMITEN (no se borran los secrets ya existentes).
# ============================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${HERE}/.actions-secrets.env"

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: 'gh' no está instalado o no está en el PATH." >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: no has iniciado sesión. Ejecuta primero:  gh auth login" >&2
  exit 1
fi
if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: falta ${ENV_FILE}." >&2
  echo "Copia la plantilla y rellénala:" >&2
  echo "  cp scripts/.actions-secrets.env.example scripts/.actions-secrets.env" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# Detecta el repo del remoto origin si no se fijó en el .env
if [ -z "${REPO:-}" ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi
if [ -z "${REPO:-}" ]; then
  echo "ERROR: no se pudo determinar REPO (owner/repo)." >&2
  exit 1
fi
echo "Repo destino: $REPO"

set_var() {  # nombre, valor
  local name="$1" val="${2:-}"
  if [ -z "$val" ]; then echo "  · var $name (vacío) -> omitido"; return; fi
  gh variable set "$name" --repo "$REPO" --body "$val" >/dev/null
  echo "  ✓ var $name = $val"
}

set_secret() {  # nombre, valor
  local name="$1" val="${2:-}"
  if [ -z "$val" ]; then echo "  · secret $name (vacío) -> omitido"; return; fi
  printf '%s' "$val" | gh secret set "$name" --repo "$REPO" >/dev/null
  echo "  ✓ secret $name (oculto)"
}

echo "== Variables =="
set_var DEPLOY_VPS   "${DEPLOY_VPS:-}"
set_var DEPLOY_WEB   "${DEPLOY_WEB:-}"
set_var BUILD_MOBILE "${BUILD_MOBILE:-}"

echo "== Secrets: VPS =="
set_secret VPS_HOST    "${VPS_HOST:-}"
set_secret VPS_USER    "${VPS_USER:-}"
set_secret VPS_SSH_KEY "${VPS_SSH_KEY:-}"

echo "== Secrets: Vercel / Web =="
set_secret VERCEL_TOKEN              "${VERCEL_TOKEN:-}"
set_secret VERCEL_ORG_ID            "${VERCEL_ORG_ID:-}"
set_secret VERCEL_PROJECT_ID        "${VERCEL_PROJECT_ID:-}"
set_secret PROD_SUPABASE_URL        "${PROD_SUPABASE_URL:-}"
set_secret PROD_SUPABASE_ANON_KEY   "${PROD_SUPABASE_ANON_KEY:-}"
set_secret PROD_BACKEND_URL         "${PROD_BACKEND_URL:-}"
set_secret PROD_STRIPE_PRICE_STARTER  "${PROD_STRIPE_PRICE_STARTER:-}"
set_secret PROD_STRIPE_PRICE_PRO      "${PROD_STRIPE_PRICE_PRO:-}"
set_secret PROD_STRIPE_PRICE_BUSINESS "${PROD_STRIPE_PRICE_BUSINESS:-}"

echo "Listo. Revisa en: https://github.com/${REPO}/settings/secrets/actions"
