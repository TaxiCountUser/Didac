# Restringir la API key de Firebase (N-06)

La app Android incluye `frontend/android/app/google-services.json`, que contiene
una **API key de Firebase** (`AIzaSy…`). Esa clave es **pública por diseño** (va
dentro de cada APK y se puede extraer); **no** es un secreto de servidor (enviar
push requiere el service-account `FCM_SERVICE_ACCOUNT`, no esta clave).

Aun así, conviene **restringirla** para que, aunque sea pública, solo la pueda
usar **tu app firmada** y se evite el abuso de cuota. Esto cierra el hallazgo
**N-06** de la auditoría de seguridad (severidad baja).

## Datos del proyecto

| Dato | Valor |
|---|---|
| Proyecto Firebase / GCP | `taxicount-75bc2` |
| Paquete Android | `app.taxicount` |
| API key a restringir | `AIzaSyA_nhQLXsaD1KuBQ3-L-q_VJXkwGPg0iXM` |

## Huellas del keystore de release (sideload)

Keystore: `backups/taxicount-upload.jks` (alias `taxicount`).

| Algoritmo | Huella |
|---|---|
| **SHA-1** | `DF:87:2D:D0:CB:76:29:30:95:A3:DD:BA:61:67:09:62:0F:2D:78:EE` |
| **SHA-256** | `DD:B6:EC:53:68:D6:73:61:BE:C2:27:B9:B8:81:09:11:CA:C3:DB:38:09:79:C7:6F:80:5B:45:C0:03:4D:35:5A` |

Para regenerarlas (la contraseña está en `backups/keystore-password.txt`, **no**
se versiona):

```bash
PW=$(tr -d ' \r\n' < backups/keystore-password.txt)
keytool -list -v -keystore backups/taxicount-upload.jks -storepass "$PW" \
  | grep -iE "Alias|SHA1|SHA256"
```

## Paso 1 — Restringir por app (lo importante)

1. Google Cloud Console → **APIs y servicios → Credenciales**:
   https://console.cloud.google.com/apis/credentials?project=taxicount-75bc2
2. Abre la clave `AIzaSyA_nhQ…` (suele llamarse *"Android key (auto created by Firebase)"*).
3. **Restricciones de aplicación → Apps de Android → Agregar elemento:**
   - Nombre del paquete: `app.taxicount`
   - Huella SHA-1: `DF:87:2D:D0:CB:76:29:30:95:A3:DD:BA:61:67:09:62:0F:2D:78:EE`
4. **Guardar** (propaga en ~5 min).

## Paso 2 — (Opcional) Restringir por API

En la misma pantalla, **Restricciones de API → Restringir clave** y marca solo:
- Firebase Installations API
- FCM Registration API
- Firebase Cloud Messaging API

> ⚠️ Hazlo **después** de verificar que el push sigue funcionando con el Paso 1.
> Si restringes de más, las notificaciones dejan de llegar. En caso de duda,
> deja "No restringir clave" en API y quédate con el Paso 1 (mitiga el riesgo real).

## Paso 3 — (Recomendado) Registrar la SHA-1 en Firebase

https://console.firebase.google.com/project/taxicount-75bc2/settings/general →
app Android `app.taxicount` → **Agregar huella digital** → pega la SHA-1.
(Necesario si algún día usas Dynamic Links / Google Sign-In nativo.)

## Paso 4 — Verificar

Tras ~5-10 min, abre la app (build firmada con el keystore) y confirma que
**llega una notificación push**. Si llega, N-06 queda resuelto.

## ⚠️ Al publicar en Google Play (pendiente, pausado por RGPD)

Con **Play App Signing**, Google **re-firma** la app con OTRA clave, así que el
SHA-1 de producción será distinto. Habrá que **añadir también** el SHA-1 de
*Play App Signing*:

1. Play Console → **Configuración → Integridad de la app → Certificado de la
   clave de firma de la app** → copia su SHA-1 (y SHA-256).
2. Añádelo a la restricción de la API key (Paso 1) **y** a Firebase (Paso 3).

Si no se hace, el push y los servicios Firebase fallarán en las builds de Play.
