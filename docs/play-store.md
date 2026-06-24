# Publicar TaxiCount en Google Play (prueba interna)

Todo lo que necesitas para subir la app a Google Play, con los textos listos para
copiar. Lo técnico (proyecto Android, build en la nube, firma) ya está hecho; ver
[test-build.md](test-build.md). Aquí va lo de la **ficha de la tienda**.

> Lo que solo puedes hacer tú: crear la cuenta de **Google Play Console**
> (pago único de 25 $) y generar/guardar la **clave de firma** (keystore). No
> puedo crear cuentas, pagar ni manejar tu clave por ti.

## 0. Requisitos previos
- Backend desplegado en la nube (Render) y `PROD_*` en los secrets de GitHub
  (ver test-build.md). Sin esto el APK/AAB no sirve en un móvil real.
- **Política de privacidad** (Play la exige): ya la sirve tu backend en
  **`https://<tu-backend>.onrender.com/privacy`**. Usa esa URL en la ficha.
  Personaliza empresa/contacto con las env `PRIVACY_COMPANY` y `PRIVACY_CONTACT`.

## 1. Crear la clave de firma (una vez; guárdala MUY bien)
```bash
keytool -genkey -v -keystore upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```
Codifícala y añádela a los secrets de GitHub (Settings → Secrets → Actions):
```bash
base64 -w0 upload-keystore.jks > keystore.b64   # macOS: base64 -i upload-keystore.jks
```
| Secret | Valor |
| ------ | ----- |
| `ANDROID_KEYSTORE_BASE64` | contenido de `keystore.b64` |
| `ANDROID_KEYSTORE_PASSWORD` | contraseña del store |
| `ANDROID_KEY_ALIAS` | `upload` |
| `ANDROID_KEY_PASSWORD` | contraseña de la clave |

## 2. Generar el .aab firmado
GitHub → **Actions → "Build APK / AAB (manual)" → Run workflow** (con el AAB
marcado) → descarga el artefacto **`taxicount-aab`** (`app-release.aab`).

## 3. Crear la app en Play Console
1. https://play.google.com/console → **Crear app**.
2. Nombre: **TaxiCount** · Idioma predeterminado: Català o Español · Tipo: App ·
   Gratis.
3. Activa **Play App Signing** cuando lo pida (recomendado).

## 4. Ficha de Play Store (textos listos para pegar)

**Nombre (30):** `TaxiCount`

**Descripción corta (80):**
`Gestiona tu flota de taxi: carreras por voz, gastos, km y seguimiento.`

**Descripción completa (catalán):**
```
TaxiCount és l'eina per gestionar una flota de taxi de manera senzilla.

CONDUCTOR
• Registra les carreres per VEU en català o castellà: digues l'origen, el destí, l'import, l'empresa i els quilòmetres, i l'app ho omple sol.
• Registre manual ràpid quan vulguis.
• Consulta els teus beneficis del dia, setmana, mes o any.

TITULAR DE LA FLOTA
• Panell de control amb ingressos, despeses i informes (Excel i PDF).
• Vehicles amb km i manteniment: ITV, assegurança, targeta de transport i revisions.
• Assigna conductors a vehicles i localitza el vehicle durant la jornada.
• Incidències i comunicació amb els conductors.

Disponible en català, castellà i anglès.
```

**Descripción completa (castellano):**
```
TaxiCount es la herramienta para gestionar una flota de taxi de forma sencilla.

CONDUCTOR
• Registra las carreras por VOZ en catalán o castellano: di el origen, el destino, el importe, la empresa y los kilómetros, y la app lo rellena solo.
• Registro manual rápido cuando quieras.
• Consulta tus beneficios del día, semana, mes o año.

TITULAR DE LA FLOTA
• Panel de control con ingresos, gastos e informes (Excel y PDF).
• Vehículos con km y mantenimiento: ITV, seguro, tarjeta de transporte y revisiones.
• Asigna conductores a vehículos y localiza el vehículo durante la jornada.
• Incidencias y comunicación con los conductores.

Disponible en catalán, castellano e inglés.
```

- **Categoría:** Empresa (o Productividad).
- **Correo de contacto:** el tuyo.
- **Política de privacidad:** `https://<tu-backend>.onrender.com/privacy`

## 5. Cuestionario "Seguridad de los datos" (Data safety)
Declara EXACTAMENTE lo que hace la app (todo se transmite cifrado por HTTPS;
el usuario puede pedir borrado):

| Dato | ¿Se recoge? | Finalidad |
| ---- | ----------- | --------- |
| Correo electrónico / nombre | Sí | Gestión de la cuenta |
| Ubicación aproximada y precisa | Sí | Seguimiento del vehículo durante la jornada |
| Grabaciones de audio (voz) | Sí | Transcribir la carrera (no se almacena el audio) |
| Actividad de la app (carreras, gastos, km) | Sí | Funcionamiento del servicio |

- ¿Se comparten con terceros? Sí, con **proveedores que procesan por cuenta del
  responsable** (Supabase, Groq/OpenAI para la transcripción, Stripe, Render).
- ¿Cifrado en tránsito? **Sí**. ¿El usuario puede pedir el borrado? **Sí**.

## 6. Clasificación de contenido
Responde el cuestionario (app de empresa, sin contenido sensible) → saldrá
**PEGI 3 / Apto para todos**.

## 7. Prueba interna
1. **Pruebas → Prueba interna → Crear versión** → sube el `.aab`.
2. Añade los correos de los profesionales como testers.
3. Comparte el **enlace de aceptación**; ellos lo abren, aceptan e instalan
   desde Play. (La primera revisión de Google suele tardar minutos/horas.)

## Resumen de lo que falta por tu parte
- [ ] Backend en Render + secrets `PROD_*` (test-build.md).
- [ ] Crear keystore + secrets `ANDROID_*`.
- [ ] Cuenta de Google Play Console (25 $).
- [ ] Ejecutar el workflow → subir el `.aab` → prueba interna.
