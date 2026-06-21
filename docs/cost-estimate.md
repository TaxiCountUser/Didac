# Estimación de coste mensual — TaxiCount (Fase 6)

Objetivo: **< 150 €/mes**. ✅ Estimación dentro del límite.

## Desglose

| Servicio | Plan | Coste/mes | Notas |
| -------- | ---- | --------- | ----- |
| **Supabase** | Pro | ~25 € | Postgres + Auth + Realtime + Storage + backups diarios (7 días). |
| **DigitalOcean** | App Platform `basic-xs` | ~12 € | Backend Fastify (1 instancia). |
| **OpenAI Whisper** | uso | ~50 € | 150 transcripciones/día × 30 × ~1 min × $0.006/min ≈ $27; se presupuesta ~50 € con margen. |
| **Vercel/Netlify** | Free | 0 € | Hosting de Flutter Web. |
| **Sentry** | Developer (free) | 0 € | 5k eventos/mes. |
| **UptimeRobot** | Free | 0 € | 50 monitores, intervalo 5 min. |
| **Dominio** `taxicount.app` | anual | ~1,5 €/mes | ~18 €/año prorrateado. |
| **Stripe** | por transacción | 0 € fijo | Comisión por pago, no coste fijo. |
| **TOTAL** | | **~88,5 €/mes** | **41 % por debajo del límite de 150 €.** |

## Controles de coste implementados

- **Whisper**: límite diario de transcripciones por usuario (`429` al superar
  `TRANSCRIBE_DAILY_LIMIT`, def. 150) + caché en memoria por usuario → evita
  re-transcribir el mismo audio y limita el gasto variable, que es el principal
  riesgo de coste.
- **Supabase Pro** (no Team/Enterprise): suficiente para el MVP; subir solo si
  el volumen lo exige.
- **Backend**: 1 instancia `basic-xs`; escalar solo si las pruebas de carga en
  staging lo justifican (ver [performance-report.md](performance-report.md)).
- **Informes**: caché de 10 min + timeout 30 s → evita trabajo de CPU repetido.

## Margen y crecimiento

Con ~88 €/mes quedan ~62 € de margen mensual. Si el uso de Whisper se dispara,
el límite diario lo acota; si se necesita más cómputo, subir a `basic-s` (~24 €)
seguiría dentro del presupuesto (~100 €).
