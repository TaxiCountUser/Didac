# Procedimiento de Gestión de Brechas de Seguridad — TaxiCount

> **BORRADOR para revisión legal.** No es asesoramiento jurídico. Arts. 33 y 34
> RGPD y Directrices EDPB sobre notificación de brechas.
>
> Responsable: Didac Oliveras Galvez · Contacto: didakdp.5@gmail.com.
> Última actualización: 01/07/2026.

Una **violación de seguridad de los datos personales** ("brecha") es cualquier
incidente que ocasione la destrucción, pérdida, alteración, comunicación o acceso
no autorizados a datos personales (confidencialidad, integridad o disponibilidad).

## 1. Roles y responsable de incidentes
- **Responsable de incidentes:** Didac Oliveras Galvez (contacto anterior).
- Toda persona con acceso (incluidos proveedores) debe comunicar de inmediato
  cualquier sospecha de brecha al responsable de incidentes.

## 2. Fases del procedimiento

### 2.1 Detección y registro (inmediato)
Anotar en el **Registro de Brechas** (§5): fecha/hora de detección, quién la
detecta, sistemas afectados y descripción inicial.

### 2.2 Contención (lo antes posible)
Limitar el impacto: revocar credenciales/claves comprometidas, cerrar el acceso
afectado, aislar el sistema, revertir cambios maliciosos, forzar cambio de
contraseñas si procede.

### 2.3 Evaluación del riesgo
Valorar: tipo de brecha, categorías y volumen de datos e interesados afectados,
facilidad de identificación, gravedad de las consecuencias y probabilidad. Con
esto se decide si hay **riesgo** (→ notificar a la AEPD) y si hay **alto riesgo**
(→ comunicar a los interesados).

### 2.4 Notificación a la autoridad de control (AEPD) — Art. 33
- **Si la brecha entraña un riesgo** para los derechos y libertades: notificar a
  la **AEPD** (sede electrónica) **sin dilación indebida y, a ser posible, en un
  plazo máximo de 72 horas** desde que se tiene constancia.
- Si se notifica pasadas las 72 h, indicar los motivos del retraso.
- Contenido mínimo: naturaleza de la brecha, categorías y nº aproximado de
  interesados y registros, datos de contacto, consecuencias probables y medidas
  adoptadas o propuestas.
- Si no se conoce todo, puede notificarse **por fases**.

### 2.5 Comunicación a los interesados — Art. 34
- **Si la brecha entraña ALTO riesgo** para los interesados: comunicárselo **sin
  dilación indebida**, en lenguaje claro (naturaleza de la brecha, contacto,
  consecuencias probables, medidas adoptadas y recomendaciones).
- No es necesaria si: los datos estaban cifrados/ininteligibles, se han tomado
  medidas que eliminan el alto riesgo, o supondría un esfuerzo desproporcionado
  (en tal caso, comunicación pública).

### 2.6 Cierre y lecciones aprendidas
Completar el registro, documentar la causa raíz y aplicar medidas para evitar la
repetición.

## 3. Rol de encargado y subencargados (cadena de notificación)
- **Como encargado** (datos de flota por cuenta del cliente): si la brecha afecta
  a datos tratados por cuenta de un cliente, **notificar al cliente (responsable)
  sin dilación indebida**; es el cliente quien, en su caso, notifica a la AEPD.
- **Subencargados** (Supabase, Render, Groq/OpenAI, Firebase, Stripe): sus DPA
  obligan a notificarnos sus brechas sin dilación; al recibir tal aviso, se
  activa este procedimiento.

## 4. Plazos de referencia
| Acción | Plazo |
|---|---|
| Comunicación interna de la sospecha | Inmediata |
| Contención | Lo antes posible |
| Notificación AEPD (si hay riesgo) | ≤ 72 h desde la constancia |
| Comunicación a interesados (si alto riesgo) | Sin dilación indebida |
| Notificación al cliente (rol encargado) | Sin dilación indebida |

## 5. Registro de Brechas (plantilla)
Conservar TODAS las brechas (aunque no se notifiquen), Art. 33.5.

| Campo | Contenido |
|---|---|
| Nº / referencia | |
| Fecha y hora de la brecha (o estimación) | |
| Fecha y hora de detección | |
| Persona que detecta / notifica | |
| Descripción de la brecha | |
| Sistemas y datos afectados | |
| Categorías y nº aproximado de interesados | |
| Categorías y nº aproximado de registros | |
| Evaluación del riesgo (bajo/riesgo/alto) | |
| ¿Notificada a la AEPD? (sí/no, fecha, motivo si tardía) | |
| ¿Comunicada a los interesados? (sí/no, fecha, medio) | |
| Medidas de contención y correctivas | |
| Causa raíz y lecciones aprendidas | |
| Estado (abierta/cerrada) | |

## 6. Contactos útiles
- **AEPD:** www.aepd.es (sede electrónica para notificación de brechas).
- **Responsable de incidentes TaxiCount:** didakdp.5@gmail.com.
