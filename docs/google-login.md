# Activar "Entrar con Google"

El código ya está en la app (botón "Entrar con Google"). Solo falta la
configuración, que se hace una vez (yo no puedo crear cuentas/credenciales):

## 1. Google Cloud (crear el cliente OAuth)
1. https://console.cloud.google.com → crea un proyecto (o usa uno).
2. **APIs y servicios → Pantalla de consentimiento OAuth** → tipo *Externo* →
   rellena nombre de la app y correo de soporte → guarda.
3. **Credenciales → Crear credenciales → ID de cliente de OAuth → Aplicación web**.
4. En **URIs de redireccionamiento autorizados** añade exactamente:
   ```
   https://ckgzxumxdwopnufrznxr.supabase.co/auth/v1/callback
   ```
5. Copia el **Client ID** y el **Client secret**.

## 2. Supabase (activar el proveedor)
1. Supabase → **Authentication → Providers → Google** → actívalo.
2. Pega el **Client ID** y el **Client secret** del paso anterior → guarda.
3. Supabase → **Authentication → URL Configuration → Redirect URLs** → añade:
   - `app.taxicount://login-callback`  (para el móvil)
   - la URL de tu web si la publicas (p. ej. `https://tu-web/...`)

## 3. Listo
- En **web** funciona ya (redirige en el navegador).
- En el **APK**, el botón abre el navegador, te logas con Google y vuelve a la
  app por el deep link `app.taxicount://login-callback` (ya configurado en el
  AndroidManifest). No hace falta reconstruir el APK por esto.

## Error frecuente
> "Se requiere al menos un ID de cliente cuando el inicio de sesión de Google
> está habilitado. Lista separada por comas de ID de clientes…"

Es el campo **Client IDs** de Supabase (Authentication → Providers → Google).
Está vacío porque aún no has creado el cliente OAuth en Google Cloud. Haz el
**paso 1** (crear "Aplicación web" y copiar su Client ID), pega ese Client ID en
ese campo **Client IDs** y el secreto en **Client Secret**, y guarda.

## Notas
- El primer usuario que entre con Google se crea como **dueño** (se le crea una
  empresa con el nombre de su correo); puedes cambiar el nombre en Ajustes.
- Los **conductores** siguen entrando con el correo/contraseña que les da el jefe
  (o pueden vincular su Google al mismo correo si coincide).
