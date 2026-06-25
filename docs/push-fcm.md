# Notificaciones push (Firebase / FCM)

El push "que suena" (aunque la app esté cerrada) necesita Firebase Cloud
Messaging. Esto requiere **tu** alta en Firebase. El orden importa: primero el
alta (paso 1–2), porque sin `google-services.json` el build de Android falla.

La base ya está hecha en el código:
- Tabla `device_tokens` (cada usuario guarda su token).
- Backend `POST /api/v1/notify-incident` (envía al destinatario correcto). Solo
  se activa si existe la variable `FCM_SERVICE_ACCOUNT`.

## 1. Crear el proyecto Firebase
1. https://console.firebase.google.com → **Agregar proyecto** → nombre `TaxiCount` → crear (puedes desactivar Analytics).

## 2. App Android + google-services.json  (necesario para compilar)
1. En el proyecto → icono **Android** ("Agregar app").
2. **Nombre del paquete**: `app.taxicount`  (exactamente).
3. Registrar app → **Descargar `google-services.json`**.
4. Guárdalo en: `frontend/android/app/google-services.json`
   (o pásame su contenido y lo coloco yo; no es secreto, va dentro de la app).

## 3. Clave de servidor para enviar (cuenta de servicio)
1. Firebase Console → **⚙ Configuración del proyecto → Cuentas de servicio**.
2. **Generar nueva clave privada** → descarga un JSON. **Esto SÍ es secreto.**
3. En **Render** (servicio del backend), dos opciones:
   - **Secret File** (recomendado): Environment → Secret Files → nombre
     `fcm.json`, contenido = el JSON. Se monta en `/etc/secrets/fcm.json` y el
     backend lo lee solo. (Si usas otro nombre, define `FCM_SERVICE_ACCOUNT_FILE`
     con la ruta `/etc/secrets/<nombre>`.)
   - **Variable de entorno**: `FCM_SERVICE_ACCOUNT` = el JSON (vale multilínea).
   - No lo pegues en el chat ni lo subas al repo. Tras ponerlo, **Manual Deploy**.

## 4. (Lo hago yo) Cableado en la app
Cuando exista el `google-services.json`:
- `firebase_core` + `firebase_messaging` en `pubspec.yaml`.
- Plugin `com.google.gms.google-services` en Gradle.
- Pedir permiso de notificaciones, obtener el token FCM y guardarlo en
  `device_tokens`; manejar mensajes en primer/segundo plano.
- La app llamará a `/api/v1/notify-incident` al crear una incidencia o mensaje.

## Notas
- El **badge** (contador) ya funciona sin Firebase. Esto añade el aviso sonoro.
- Empezamos por **Android (APK)**, que es donde pruebas con profesionales. El
  push en **web** (service worker + VAPID) se puede añadir después.
