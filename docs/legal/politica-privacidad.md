# Política de Privacidad — TaxiCount

> **BORRADOR para revisión legal.** No es asesoramiento jurídico. Debe validarlo
> un profesional de protección de datos antes de publicarlo. Basado en el
> RGPD (Reglamento UE 2016/679) y la LOPDGDD 3/2018 (España).
>
> Versión del documento: **v1** · Última actualización: 01/07/2026
> (La versión debe coincidir con `kLegalVersion` en la app para el control de aceptación.)

## 1. Quiénes somos y qué es TaxiCount

TaxiCount es una **herramienta de registro y gestión** para profesionales del
taxi (autónomos y empresas de flota): una "agenda/Excel virtual" que facilita
apuntar carreras, gastos, kilómetros y vehículos, antes gestionados en papel o
en hojas de cálculo. **TaxiCount no es una gestoría, no emite facturas ni presta
servicios de asesoría fiscal o contable.**

- **Titular del servicio (proveedor de la herramienta):** Didac Oliveras Galvez, NIF 41556654R, domicilio C/ Tapis 37, 1r, 17600 Figueres (Girona).
- **Contacto de privacidad:** didakdp.5@gmail.com.
- **Delegado de Protección de Datos (DPO):** no se designa; dado el volumen de tratamiento no concurren los supuestos del Art. 37 RGPD (a revisar por asesor legal). Para cualquier cuestión de privacidad, usa el contacto anterior.

## 2. Roles en el tratamiento (importante)

- Respecto a **tus datos de cuenta y de la relación contractual** (alta,
  suscripción, soporte, seguridad de la plataforma), TaxiCount actúa como
  **responsable del tratamiento**.
- Respecto a los **datos que tú introduces sobre tu actividad** (tus conductores,
  tus carreras, tus clientes), TaxiCount actúa como **encargado del tratamiento**
  por tu cuenta (Art. 28 RGPD): solo los trata para prestarte la herramienta,
  **nunca para finalidades propias**. Las condiciones de ese encargo están en el
  *Contrato de servicio y su Anexo de tratamiento de datos*.

## 3. Qué datos tratamos

| Categoría | Ejemplos | De quién |
|---|---|---|
| Cuenta | correo, nombre, nombre de usuario, nº de licencia (opcional), avatar | titular y conductores |
| Autenticación | contraseña (cifrada por el proveedor de identidad) | titular y conductores |
| Ubicación | **última posición** del conductor, **solo con la app abierta y en primer plano** (sin histórico ni seguimiento en segundo plano) | conductores |
| Voz | audio **solo al pulsar el botón de dictado**, para convertirlo en texto; **el audio no se almacena**, solo el texto/los datos de la carrera | conductores |
| Actividad | carreras, importes, gastos, km, vehículos, incidencias | introducidos por el usuario |
| Suscripción | identificadores de cliente/suscripción del proveedor de pagos | titular |
| Técnicos | token de dispositivo (notificaciones), días de uso, dirección IP (seguridad/auditoría) | usuarios |

> **Datos de terceros (clientes/pasajeros):** los campos de origen, destino y la
> descripción de una carrera **pueden** contener datos de terceros que el
> conductor decide introducir. La responsabilidad de introducir esos datos, y de
> informar a esas personas si procede, corresponde al **profesional del taxi**,
> no a TaxiCount.

## 4. Para qué los usamos y con qué base legal (Art. 6 RGPD)

| Finalidad | Base legal |
|---|---|
| Prestar la herramienta (registrar carreras/gastos, informes, gestión de flota) | **Ejecución de contrato** (Art. 6.1.b) |
| Cobro de la suscripción del servicio | **Ejecución de contrato** (Art. 6.1.b) |
| Mostrar al titular la **última ubicación** del vehículo en jornada | **Interés legítimo** del empleador en el control operativo del vehículo (Art. 6.1.f), informando al conductor (LOPDGDD Art. 90) |
| Dictado por voz | Ejecución del servicio / interés legítimo (Art. 6.1.b/f) |
| Notificaciones operativas | Interés legítimo (Art. 6.1.f) |
| Seguridad, prevención de fraude y auditoría | Interés legítimo (Art. 6.1.f) |

No usamos tus datos para publicidad ni los vendemos.

## 5. Proveedores que intervienen (encargados/subencargados)

TaxiCount usa herramientas de terceros **únicamente** para funcionar. Cada uno
trata los datos según sus propias condiciones de tratamiento (DPA):

| Proveedor | Función | Ubicación / transferencia |
|---|---|---|
| Supabase | base de datos, autenticación y almacenamiento | UE (verificar región en la consola de Supabase) |
| Render | alojamiento del servidor | UE (Frankfurt) |
| Groq **o** OpenAI | transcripción de las notas de voz | **EE. UU.** (ver §6) |
| Google Firebase (FCM) | notificaciones push (token de dispositivo) | EE. UU. |
| Stripe | cobro de la suscripción | UE/EE. UU. |
| Sentry | registro de errores de la app (incluye IP) | según su configuración |

## 6. Transferencias internacionales (Cap. V RGPD)

Algunos proveedores tratan datos **fuera de la UE (EE. UU.)**. En esos casos, la
transferencia se ampara en una **decisión de adecuación** (marco *EU-US Data
Privacy Framework*) cuando el proveedor está certificado, o en **Cláusulas
Contractuales Tipo (Art. 46)** con evaluación de la transferencia. En concreto,
la transcripción de voz se envía a un proveedor en EE. UU.: actualmente **Groq**
(fase de desarrollo) y **OpenAI** (certificado en el EU-US DPF) en producción.

## 7. Conservación

- **Datos de cuenta:** mientras la cuenta esté activa; se suprimen o anonimizan
  tras la baja, salvo obligación legal de conservación.
- **Datos de actividad/carreras:** el **profesional del taxi** puede tener la
  obligación fiscal/mercantil de conservarlos varios años; en tal caso se
  conservan bloqueados durante ese plazo.
- **Ubicación:** solo se guarda la **última posición** (se sobrescribe); no hay
  histórico.
- **Audio de voz:** no se conserva.
- **Registros técnicos (IP/auditoría):** 12 meses.

## 8. Con quién NO compartimos y acceso del personal de TaxiCount

El personal de administración de TaxiCount **no accede al contenido económico
(importes, ingresos, balances) ni al detalle de las carreras (cliente, origen,
destino) de las empresas**: en el panel de administración esos datos aparecen
**enmascarados**. El acceso administrativo se limita a soporte, gestión de
cuentas/suscripción e incidencias, y queda **registrado (auditoría)**.

## 9. Tus derechos (Arts. 15-22 RGPD)

Acceso, rectificación, supresión, oposición, limitación y portabilidad,
escribiendo a didakdp.5@gmail.com. Responderemos en el plazo de **1 mes**
(Art. 12). Puedes reclamar ante la **Agencia Española de Protección de Datos
(AEPD)** o la autoridad de control de tu país.

## 10. Permisos del dispositivo

La app solicita **ubicación** (última posición del vehículo, solo con la app
abierta) y **micrófono** (dictado por voz). Ambos son **opcionales y revocables**
desde los ajustes del sistema.

## 11. Menores

TaxiCount es una herramienta profesional; no está dirigida a menores.

## 12. Cambios

Si actualizamos esta política, incrementaremos su versión y **te pediremos que
la aceptes de nuevo** al abrir la app.
