# Stripe — Loop #6: cupón de lanzamiento y crédito por retos

Esta parte es **configuración tuya en el panel de Stripe** (no la puede hacer el
código: implica claves secretas). El código ya está preparado para usarla.

## 1. Precios (modelo por asiento)

- **Precio base (Stripe Price):** 24 €/año y 2,50 €/mes por conductor. *(Ya son
  los valores de `frontend/lib/config.dart`: `kSeatYearly=24`, `kSeatMonthly=2.5`.)*
- **Oferta de lanzamiento:** 38 % de descuento con cupón permanente
  ⇒ ≈ **14,88 €/año** (lo que el loop llama "15 €/año"). La app muestra el precio
  base tachado y el precio con oferta (constante `kLaunchDiscountPct = 38`).

## 2. Crear el cupón permanente (TAXI2026)

1. Stripe → **Productos → Cupones → Crear cupón**.
2. Tipo: **Porcentaje**, **38 %**.
3. Duración: **Para siempre** (forever).
4. (Opcional) Restríngelo a los Prices del asiento (mensual y anual).
5. Copia el **ID del cupón** (p. ej. `TAXI2026` o el id generado).

## 3. Variables de entorno en Render (backend)

| Variable | Valor | Efecto |
|---|---|---|
| `STRIPE_LAUNCH_COUPON` | ID del cupón (paso 2) | Se **auto-aplica** en cada checkout. Si se deja vacío, el checkout permite **códigos promocionales manuales** (para campañas). |
| `STRIPE_SEAT_CREDIT_CENTS` | `250` (por defecto) | Crédito por reto completado (250 = 2,50 €). |

> `discounts` (cupón fijo) y `allow_promotion_codes` (código manual) son
> **excluyentes** en Stripe Checkout. Por eso: si defines `STRIPE_LAUNCH_COUPON`,
> se aplica ese; si no, se permiten códigos manuales.

## 4. Campañas y churn (cupones adicionales)

Crea más cupones cuando quieras (p. ej. `SUMMER2026` 50 %, o uno de recuperación
del 50 % = 12 €/año). Para usarlos:
- **Temporalmente como oferta principal:** cambia `STRIPE_LAUNCH_COUPON` al nuevo.
- **Como código que teclea el cliente:** deja `STRIPE_LAUNCH_COUPON` vacío
  (el checkout mostrará la casilla de código promocional).

## 5. Recompensa de retos = 1 mes-asiento gratis (crédito)

Cuando un conductor completa un reto (`challenge_claims.status='rewarded'`), el
jefe gana **1 mes-asiento gratis**. Se materializa como **crédito en el saldo del
cliente de Stripe** (`customer balance`), que Stripe descuenta automáticamente de
la **próxima factura**. Es idempotente (`challenge_claims.reward_redeemed_at`).

Se aplica ejecutando (admin) el endpoint:

```
POST /api/v1/admin/cron/apply-challenge-credits
```

Recorre los retos completados sin canjear, abona el crédito a los tenants que ya
tengan cliente de Stripe y los marca como canjeados. Conviene **programarlo**
(p. ej. diario) o lanzarlo a mano periódicamente. Los tenants aún en prueba (sin
cliente de Stripe) se omiten y se cobrarán cuando lo tengan.

> Requiere la migración **051** (`reward_redeemed_at`) ejecutada en Supabase.
