# Probar TaxiCount con profesionales (APK + Play Store)

Guía para poner la app en manos de probadores reales. La arquitectura de
producción completa está en [production-setup.md](production-setup.md); esto es
la versión **mínima para testear**: backend en la nube + APK construido en CI.

```
 Móvil (APK)  ──HTTPS──>  backend en Render  ──>  Supabase Cloud (DB/Auth/Realtime)
```

## Qué ya está preparado en el repo (hecho)

- ✅ Proyecto **Android** generado y configurado (`frontend/android/`): permisos
  de Internet, GPS y micrófono; `applicationId = app.taxicount.taxicount`;
  nombre visible **TaxiCount**; firma de release opcional vía `key.properties`.
- ✅ Workflow **“Build APK / AAB (manual)”** (`.github/workflows/build-apk.yml`):
  construye la app en la nube (no necesitas Android SDK en tu PC) y te deja el
  `.apk` (y el `.aab` para Play) como artefacto descargable.
- ✅ **Blueprint de Render** (`render.yaml`) para desplegar el backend con un clic.
- ✅ Backend compatible con el puerto que asigna el host (`PORT`).

## Lo que tienes que hacer tú (necesita tus cuentas)

> Yo no puedo crear cuentas ni introducir contraseñas/claves por ti. Te dejo los
> pasos exactos; son de copiar y pegar.

### 1) Supabase Cloud (gratis para empezar)

1. Crea un proyecto en https://supabase.com (región **EU**, p. ej. Frankfurt).
2. En **Settings → API** copia: `Project URL`, `anon key` y `service_role key`.
3. Aplica las migraciones (esquema de la BD). Con la [Supabase CLI](https://supabase.com/docs/guides/cli):
   ```bash
   supabase link --project-ref <tu-ref>
   supabase db push          # aplica supabase/migrations/*.sql en orden
   ```
   o con `psql` y la cadena de conexión (Settings → Database):
   ```bash
   for f in supabase/migrations/*.sql; do psql "$DATABASE_URL" -f "$f"; done
   ```
   > No cargues `supabase/seed.sql` (es solo para local).

### 2) Backend en Render

1. Crea cuenta en https://render.com.
2. **New + → Blueprint** → conecta este repositorio → Render detecta `render.yaml`.
3. Rellena las variables (no se guardan en el repo):
   - `SUPABASE_URL` = el Project URL del paso 1
   - `SUPABASE_SERVICE_ROLE_KEY` = la service_role del paso 1
   - `OPENAI_API_KEY` = tu clave de OpenAI (para voz real; opcional)
   - `CORS_ORIGIN` = `*` mientras pruebas (luego restríngelo a tu web)
4. **Deploy**. Anota la URL pública, p. ej. `https://taxicount-backend.onrender.com`.
5. Comprueba que responde: abre `…/health` en el navegador (debe dar `ok`).

> El plan free se “duerme” tras un rato sin uso (primer arranque ~30 s). Para
> pruebas con profesionales, el plan **Starter (~7 $/mes)** lo mantiene despierto.

### 3) Secrets de GitHub (para que el APK apunte a tu nube)

En el repo: **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Valor |
| ------ | ----- |
| `PROD_SUPABASE_URL` | el Project URL de Supabase |
| `PROD_SUPABASE_ANON_KEY` | la anon key de Supabase |
| `PROD_BACKEND_URL` | la URL de Render (sin barra final) |

(Los `PROD_STRIPE_PRICE_*` solo si vas a probar suscripciones.)

### 4) Construir el APK y repartirlo

1. Pestaña **Actions → “Build APK / AAB (manual)” → Run workflow**.
2. Al terminar (~5–8 min), entra en la ejecución y descarga el artefacto
   **`taxicount-apk`** → dentro está `app-release.apk`.
3. Pásalo a los probadores (WhatsApp, Drive, enlace…). En el móvil Android:
   **Ajustes → permitir “instalar apps de orígenes desconocidos”** para la app
   desde la que lo abran, y tocar el `.apk` para instalar.

¡Listo! La app ya habla con tu backend en la nube desde cualquier sitio.

## Play Store (test interno)

Necesitas una **cuenta de Google Play Console** (pago único de 25 $, la creas tú
en https://play.google.com/console). Después:

### a) Crear la clave de subida (una sola vez, guárdala a buen recaudo)

```bash
keytool -genkey -v -keystore upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

### b) Añadir la firma a los secrets de GitHub

```bash
# Codifica el keystore en base64 (macOS/Linux):
base64 -w0 upload-keystore.jks > keystore.b64    # en macOS: base64 -i upload-keystore.jks
```
Secrets nuevos en GitHub:

| Secret | Valor |
| ------ | ----- |
| `ANDROID_KEYSTORE_BASE64` | contenido de `keystore.b64` |
| `ANDROID_KEYSTORE_PASSWORD` | la contraseña del store |
| `ANDROID_KEY_ALIAS` | `upload` |
| `ANDROID_KEY_PASSWORD` | la contraseña de la clave |

### c) Generar el `.aab` y subirlo

1. **Actions → Run workflow** (con “Construir también el .aab” marcado).
2. Descarga el artefacto **`taxicount-aab`** (`app-release.aab`).
3. En Play Console: crea la app → **Pruebas → Prueba interna** → sube el `.aab`
   → añade los correos de los probadores → comparte el enlace de aceptación.
   Activa **Play App Signing** (recomendado) cuando lo pida.

> La primera vez Google revisa la cuenta/app; la prueba interna suele activarse
> en minutos/horas, no días.

## Notas

- **iPhone (iOS):** requiere un Mac y cuenta de Apple Developer (99 $/año). No se
  puede construir desde este PC Windows; queda fuera de esta guía.
- **Voz real:** pon `OPENAI_API_KEY` en Render y deja `ALLOW_MOCK_TRANSCRIBE=false`.
- **Versión de la app:** se controla en `frontend/pubspec.yaml` (`version: x.y.z+build`).
  Sube el número de build en cada APK que mandes para no confundir versiones.
