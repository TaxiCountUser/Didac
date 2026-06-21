# Informe E2E de staging — TaxiCount (Fase 6)

Suite end-to-end:
[`frontend/integration_test/e2e_test.dart`](../frontend/integration_test/e2e_test.dart).
Dart puro (headless), ejecutada contra el stack local actuando como staging.

```bash
cd frontend && dart test integration_test/e2e_test.dart
```

## Flujo cubierto (1 caso, secuencial)

| Paso | Acción | Verificación |
| ---- | ------ | ------------ |
| 1 | Registro de nuevo Owner | sesión iniciada, rol `owner`, tenant creado |
| 2 | Contratación plan Starter (webhook simulado) | `subscription_status=active`, `drivers_limit=2` |
| 3 | Alta de 2 conductores + 2 vehículos | `201` en altas; ≥ 2 vehículos visibles |
| 4 | Conductor registra transacción **por voz** y **manual** | parser extrae `35.5`; 2 inserts OK (RLS con suscripción activa) |
| 5 | Owner ve el dashboard con filtro por conductor | 2 transacciones de Ana |
| 6 | Owner exporta **Excel** y **PDF** | bytes válidos (`PK` / `%PDF`), `200` |
| 7 | Logout de Driver y Owner | `currentSession == null` en ambos |

## Resultado (2026-06-21)

```
00:00 +1: E2E: registro → suscripción → flota → transacciones → dashboard → export → logout
00:00 +1: All tests passed!
```

✅ **Todos los pasos superados.** La suite es autocontenida (crea y elimina sus
datos), por lo que puede ejecutarse contra staging real sin dejar residuos.

## Nota
La "contratación de suscripción" se simula aplicando el **efecto del webhook de
Stripe** vía `service_role` (estado `active` + plan Starter), tal y como
sanciona la especificación (sin depender de Stripe en red). El procesamiento
real del webhook firmado está cubierto por `backend/tests/unit/webhook.test.js`.
