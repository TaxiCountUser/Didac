# Registro de Actividades de Tratamiento (RoPA) — TaxiCount

> **BORRADOR para revisión legal.** No es asesoramiento jurídico. Art. 30 RGPD.
> Aunque el titular tenga <250 personas, el registro es exigible porque el
> tratamiento **no es ocasional** (incluye geolocalización de trabajadores).
>
> Responsable/Encargado: **Didac Oliveras Galvez**, NIF 41556654R, C/ Tapis 37,
> 1r, 17600 Figueres (Girona). Contacto: didakdp.5@gmail.com · DPO: no designado.
> Última actualización: 01/07/2026.

TaxiCount tiene un **doble rol**: es **responsable** de sus propias cuentas y de
la relación con el cliente, y **encargado** de los datos de flota que el cliente
introduce. Este registro recoge ambas partes.

---

## PARTE A — Como RESPONSABLE del tratamiento (Art. 30.1)

### A1. Gestión de cuentas de usuario
- **Finalidad:** alta, autenticación y gestión de cuentas (titulares y conductores).
- **Base legal:** ejecución de contrato (Art. 6.1.b).
- **Interesados:** titulares (autónomos/empresas) y conductores.
- **Categorías de datos:** correo, nombre, nombre de usuario, nº de licencia
  (opcional), avatar, contraseña (cifrada por el proveedor de identidad).
- **Destinatarios/encargados:** Supabase (BD/Auth), Render (hosting).
- **Transferencias internacionales:** no (proveedores en UE). *(Verificado UE.)*
- **Conservación:** mientras la cuenta esté activa; supresión/anonimización tras baja.
- **Medidas de seguridad:** ver §Medidas (común).

### A2. Facturación y suscripción del servicio
- **Finalidad:** cobro de la suscripción del servicio (por asiento).
- **Base legal:** ejecución de contrato (Art. 6.1.b).
- **Interesados:** titulares (clientes).
- **Datos:** identificadores de cliente/suscripción del proveedor de pagos.
- **Encargados:** Stripe.
- **Transferencias:** Stripe (UE/EE. UU.) con garantías (DPF/CCT).
- **Conservación:** durante la relación; los importes de suscripción, el plazo
  legal aplicable.

### A3. Notificaciones push
- **Finalidad:** avisos operativos de la app.
- **Base legal:** interés legítimo (Art. 6.1.f).
- **Interesados:** titulares y conductores.
- **Datos:** token de dispositivo.
- **Encargados:** Google Firebase (FCM).
- **Transferencias:** EE. UU. (Google, EU-US DPF).
- **Conservación:** mientras el dispositivo esté registrado.

### A4. Seguridad, prevención de fraude y auditoría
- **Finalidad:** proteger la plataforma, detectar abusos y registrar acciones admin.
- **Base legal:** interés legítimo (Art. 6.1.f).
- **Interesados:** todos los usuarios.
- **Datos:** dirección IP, registros de acciones administrativas, señales antifraude.
- **Encargados:** Supabase, Render.
- **Transferencias:** no.
- **Conservación:** registros técnicos/IP **12 meses**.

---

## PARTE B — Como ENCARGADO del tratamiento (Art. 30.2)

Tratamiento **por cuenta de cada cliente** (responsable): registro y gestión de
su actividad de taxi mediante la herramienta.

- **Responsables por cuenta de quienes se trata:** los clientes (autónomos/
  empresas del taxi) que usan TaxiCount. Contrato Art. 28 en
  `contrato-servicio-y-dpa.md`.
- **Categorías de tratamiento:**
  - Registro de carreras/gastos/km/vehículos e informes.
  - **Última ubicación** del conductor (primer plano, app abierta).
  - Transcripción de notas de voz (el audio no se almacena).
- **Categorías de interesados:** conductores del cliente y, en su caso,
  clientes/pasajeros mencionados en las carreras.
- **Categorías de datos:** identificativos y de contacto de conductores;
  actividad (importes/km/origen/destino/descripción); última ubicación.
  **No se tratan categorías especiales (Art. 9)** de forma intencionada.
- **Subencargados:** Supabase, Render, Groq/OpenAI (voz), Firebase (push),
  Stripe (pagos). Listado en la Política de Privacidad.
- **Transferencias internacionales:** Groq/OpenAI y Firebase (EE. UU.) con
  garantías (DPF/CCT). Supabase/Render en UE.
- **Conservación:** carreras/actividad **5 años** (obligación fiscal/mercantil
  del cliente); tras baja de empresa, cierre lógico y conservación 5 años, luego
  purga. Ubicación: solo última posición (sin histórico). Audio: no se conserva.
- **Medidas de seguridad:** ver §Medidas (común).

---

## Medidas técnicas y organizativas (común, Art. 32)

- Cifrado en tránsito (TLS) y en reposo (proveedor).
- Control de acceso por filas (RLS) con aislamiento por empresa (tenant).
- Autenticación gestionada; cambio forzado de contraseña temporal.
- **El personal de administración no accede al contenido económico ni a las
  carreras de los clientes** (enmascarado); acciones admin auditadas.
- Rate-limiting, cabeceras de seguridad, secretos fuera del repositorio,
  escáneres de seguridad en CI, copias de seguridad diarias.

## Revisión

Revisar este registro ante cualquier cambio de finalidad, proveedor, plazo de
conservación o categoría de datos.
