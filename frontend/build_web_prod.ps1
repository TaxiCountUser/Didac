# ============================================================
# TaxiCount - Compila la web apuntando a PRODUCCIÓN y la sirve.
# La clave Supabase la introduces TÚ aquí; no se guarda en ningún sitio.
#
# Uso (desde PowerShell):
#   cd C:\Users\Usuario\Documents\TaxiCount\frontend
#   .\build_web_prod.ps1
# ============================================================
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot   # carpeta frontend/

# Valores públicos (no secretos) de tu producción:
$SUPABASE_URL = 'https://ckgzxumxdwopnufrznxr.supabase.co'
$BACKEND_URL  = 'https://taxicount-backend.onrender.com'

Write-Host ''
Write-Host 'Pega tu Publishable key de Supabase (empieza por sb_publishable_...)' -ForegroundColor Cyan
$anon = Read-Host 'ANON KEY'
if ([string]::IsNullOrWhiteSpace($anon)) {
    Write-Host 'No has introducido ninguna clave. Cancelado.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'Compilando la web (puede tardar 1-2 min)...' -ForegroundColor Cyan
flutter build web --release `
  --dart-define=SUPABASE_URL=$SUPABASE_URL `
  --dart-define=SUPABASE_ANON_KEY=$anon `
  --dart-define=BACKEND_URL=$BACKEND_URL

if ($LASTEXITCODE -ne 0) {
    Write-Host 'La compilación falló. Revisa el error de arriba.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'Listo. Arrancando servidor en http://localhost:8080' -ForegroundColor Green
Write-Host 'IMPORTANTE: en el navegador abre http://localhost:8080 y pulsa Ctrl+Shift+R' -ForegroundColor Yellow
Write-Host '(para que cargue la version nueva y no la cacheada). Ctrl+C para parar.' -ForegroundColor Yellow
Write-Host ''
npx http-server build/web -p 8080 -c-1
