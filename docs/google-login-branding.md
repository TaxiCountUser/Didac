# Login con Google: mostrar "TaxiCount" (no la URL de Supabase)

**Loop #6 · Área 3.2.** En la pantalla de consentimiento de Google aparece
*"...para continuar a `<proyecto>.supabase.co`"* porque el login usa el flujo
OAuth de Supabase (`signInWithOAuth`), cuyo *redirect* apunta al callback de
Supabase. El nombre visible se controla en **Google Cloud Console**, no en el
código de la app.

## Opción A (recomendada, gratis): renombrar la app en la pantalla de consentimiento

1. Google Cloud Console → proyecto de TaxiCount → **APIs y servicios → Pantalla
   de consentimiento de OAuth**.
2. **App name / Nombre de la aplicación:** `TaxiCount`.
3. **User support email:** didakdp.5@gmail.com.
4. **App logo:** sube el icono de TaxiCount (recomendado; hace que se vea el
   nombre + logo en vez de un texto genérico).
5. **Dominios autorizados:** añade `supabase.co` (necesario para el callback) y,
   si tienes web propia, tu dominio.
6. Guardar. Tras unos minutos, la pantalla mostrará **"Acceder a TaxiCount"** con
   el logo. (La línea "para continuar a …" puede seguir mostrando el dominio del
   *redirect*; el nombre prominente ya será TaxiCount.)

## Opción B: eliminar del todo la URL de Supabase

- **Dominio de autenticación propio en Supabase** (p. ej. `auth.taxicount.app`):
  Supabase → Authentication → URL Configuration / Custom domain (función de plan
  de pago). El callback pasa a ser tu dominio y desaparece `supabase.co`.

## Opción C: login nativo de Google (YA IMPLEMENTADO en código) ✅ recomendada

El código ya usa `google_sign_in` + `signInWithIdToken` en **Android** cuando está
configurado el Client ID: el selector nativo muestra **"para continuar en
TaxiCount"**, sin navegador ni URL de Supabase. Si no se configura, se mantiene el
login por navegador (sin romper nada). En **web** sigue el flujo de navegador
(ahí solo lo quita la Opción B).

### Lo que tienes que hacer para activarlo

1. **Google Cloud → APIs y servicios → Credenciales → Crear credenciales →
   ID de cliente de OAuth → Android:**
   - **Nombre del paquete:** `app.taxicount`
   - **Huella SHA-1:** `DF:87:2D:D0:CB:76:29:30:95:A3:DD:BA:61:67:09:62:0F:2D:78:EE`
     *(es la del keystore de subida; para sideload vale. Si algún día publicas en
     Play con "App Signing de Google", añade también el SHA-1 que te da Play.)*
2. **Web Client ID:** ya tienes uno (es el que Supabase usa en su proveedor de
   Google). Cópialo: Google Cloud → Credenciales → el cliente **Web** →
   *ID de cliente* (`...apps.googleusercontent.com`). *(No hace falta crear otro;
   es el mismo que ya está en Supabase → Authentication → Providers → Google.)*
3. **GitHub → repo → Settings → Secrets and variables → Actions → New secret:**
   - Nombre: `PROD_GOOGLE_WEB_CLIENT_ID`
   - Valor: el Web Client ID del paso 2.
4. **Relanzar el build** (build-apk). El nuevo APK ya usará el login nativo.

> Sin el secret, el APK funciona igual que hasta ahora (login por navegador). El
> cambio de código es seguro y no rompe nada mientras no lo configures.

## Estado del código

- Opción A/B: solo configuración (sin cambios de código).
- **Opción C: implementada** en `login_screen.dart::_googleSignIn` (activada por
  `--dart-define=GOOGLE_WEB_CLIENT_ID`, inyectado desde el secret
  `PROD_GOOGLE_WEB_CLIENT_ID` en `build-apk.yml`).
