# Sonidos de notificación — TaxiCount

**Sonido OFICIAL de las notificaciones:** `soroll_taxi_push_ORIGINAL.wav` — creado por
Dídac (claxon de taxi, 0,43 s, WAV PCM 16 bits estéreo 44,1 kHz). Es el que lleva la app
en `frontend/android/app/src/main/res/raw/claxon.wav` (copia idéntica).

- Canal Android: `taxicount_claxon` (lo crea `MainActivity.kt`; el backend lo pide en
  `push.js`; el manifiesto lo fija como canal por defecto de FCM).
- ⚠️ Android congela el sonido de un canal al crearlo. Para CAMBIAR el sonido en
  móviles que ya tienen la app: nuevo id de canal (p. ej. `taxicount_claxon2`) en
  `MainActivity.kt`, `AndroidManifest.xml` y `backend/src/push.js`.

El resto de archivos (`1*_*.wav`, `tanda/E*.wav`) son pruebas generadas por síntesis
(sin licencias de terceros) que se descartaron.
