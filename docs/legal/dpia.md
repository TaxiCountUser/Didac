# Evaluación de Impacto (DPIA) — TaxiCount

> **BORRADOR / esqueleto para revisión legal.** Basado en el Art. 35 RGPD y las
> Directrices EDPB WP248 rev.01. Debe completarse con datos reales de escala y
> validarse por un profesional (contrastar con la lista del Art. 35.4 de la AEPD).

## 1. ¿Es obligatoria?
**Probablemente sí.** Se cumplen ≥2 criterios de WP248:
- **Observación/seguimiento sistemático:** ubicación del conductor (aunque sea
  solo última posición, primer plano y con la app abierta).
- **Evaluación/scoring:** lógica de retos y **antifraude** que marca conductores
  como "sospechosos".
- **Interesados en situación de desequilibrio:** trabajadores (relación laboral).

> Atenuantes a documentar (reducen el riesgo): sin histórico de ubicación, sin
> segundo plano, decisión de premio/sanción **siempre humana** (no Art. 22),
> audio no almacenado, y el personal de TaxiCount **no ve** dinero ni carreras.

## 2. Descripción sistemática del tratamiento
- Finalidades, categorías de datos e interesados: *ver Data Mapping del informe.*
- Flujos: cliente (web/APK) → backend (Render) / Supabase; voz → Groq/OpenAI;
  push → Firebase; pagos → Stripe.
- Responsable/encargado: *ver Contrato + Anexo.*

## 3. Necesidad y proporcionalidad
- Base legal por finalidad: *ver Política de Privacidad §4.*
- Minimización: última posición (no trail), audio no persistido, IP con plazo corto.
- Información y derechos: pantalla legal con aceptación + Política de Privacidad.

## 4. Riesgos para los derechos y libertades
| Riesgo | Prob. | Impacto | Medidas |
|---|---|---|---|
| Vigilancia laboral desproporcionada (ubicación) | Media | Medio | Solo última posición, primer plano, información al conductor (LOPDGDD Art. 90) |
| Fuga de datos económicos/carreras | Baja | Alto | RLS multi-tenant, cifrado, panel admin enmascarado |
| Transferencia a EE. UU. (voz/texto) | Media | Medio | DPF/CCT + TIA; opción de proveedor UE |
| Enumeración/acceso indebido a cuentas | Baja | Medio | Login server-side, rate-limit, auditoría |
| Datos de terceros en descripciones de carrera | Media | Bajo/Medio | Responsabilidad del profesional; minimización |

## 5. Medidas para mitigar el riesgo
*Resumen de TOMs del informe de seguridad (RLS, cifrado, auditoría, rate-limit,
enmascarado del admin, login server-side, escáneres en CI).*

## 6. Conclusión y riesgo residual
Tras aplicar las medidas de minimización y seguridad descritas (ubicación solo
última posición y en primer plano, audio no almacenado, panel de administración
enmascarado, decisiones siempre con intervención humana, cifrado y control de
acceso), el **riesgo residual se considera BAJO/aceptable**.

En su fase actual TaxiCount trata datos de un número reducido de empresas/
autónomos y conductores (fase inicial de pruebas), por lo que **no se aprecia
tratamiento "a gran escala"** en el sentido del RGPD; esto también apoya la no
obligatoriedad de designar DPO (Art. 37). **No se aprecia necesidad de consulta
previa a la AEPD (Art. 36).**

> Actualizar estas cifras y esta conclusión a medida que crezca el número de
> clientes/conductores, o si se añaden tratamientos nuevos (p. ej. seguimiento en
> segundo plano o decisiones automatizadas), que podrían cambiar la valoración.

## 7. Revisión
Revisar esta DPIA ante cualquier cambio relevante (nuevo proveedor, seguimiento
en segundo plano, decisiones automatizadas, etc.).
