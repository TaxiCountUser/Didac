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

## Opción C: login nativo de Google (cambio de código)

Sustituir `signInWithOAuth` por el paquete `google_sign_in` + `signInWithIdToken`.
El consentimiento nativo muestra "TaxiCount" directamente, sin abrir navegador ni
mostrar URL. Requiere, en Google Cloud, un **OAuth Client ID de Android** (con el
SHA-1 del keystore: `DF:87:2D:D0:CB:76:29:30:95:A3:DD:BA:61:67:09:62:0F:2D:78:EE`)
y un **Web Client ID**, y pasar el `serverClientId` a la app. Es la solución más
"limpia" en móvil, pero implica configuración de credenciales; hacerla solo si la
Opción A no basta.

## Estado del código

El flujo actual (`login_screen.dart::_googleSignIn`, `signInWithOAuth`) es
correcto y no necesita cambios para la Opción A/B. La Opción C sí requeriría
tocar el login. Pendiente: es una tarea de **Google Cloud Console** del titular.
