// ============================================================
// TaxiCount - Suscripción Stripe: asientos, cancelación, cupones, Checkout y
// Customer Portal. Fase B del troceig. Plugin de rutas que ADEMÁS agrupa toda la
// lógica de cupón (readActiveCoupon/readCouponConfigRaw/syncScheduledCoupon).
//
// Devuelve { syncScheduledCoupon } porque un cron externo (vigía de semáforos, en
// server.js) lo llama cada 15 min. Se inyectan los helpers de asientos (seatCount/
// setSeatQuantity/enforceSeatLimit: viven en server.js porque enforceSeatLimit lo
// comparte el webhook de billing.js) y las constantes Stripe module-level.
// planForPrice se importa directo de billing.js.
// ============================================================

import { planForPrice } from './billing.js';

export function registerSubscriptionRoutes(app, {
  supabase, stripe, log, adminGuard, getCaller, logAdminAction,
  seatCount, setSeatQuantity, enforceSeatLimit,
  STRIPE_PRICE_SEAT_MONTHLY, STRIPE_PRICE_SEAT_YEARLY, STRIPE_SUCCESS_URL, STRIPE_CANCEL_URL,
  MAX_SEATS,
}) {
  // Ajustar el nº de ASIENTOS PAGADOS (comprar/reducir). El jefe paga por
  // adelantado su cupo de conductores; para añadir por encima de lo pagado,
  // primero sube aquí los asientos (se cobra la parte proporcional YA). Reducir
  // por debajo de los conductores activos bloquea los más nuevos.
  app.post('/api/v1/subscription/seats', async (request, reply) => {
    if (!stripe) return reply.code(500).send({ error: 'Stripe no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (caller.role !== 'owner') return reply.code(403).send({ error: 'Solo un Owner puede cambiar los asientos' });
    const seats = Math.trunc(Number((request.body ?? {}).seats));
    if (!Number.isFinite(seats) || seats < 1) return reply.code(400).send({ error: 'Número de asientos inválido' });
    if (seats > MAX_SEATS) {
      return reply.code(400).send({ code: 'over_max_seats', error: `El máximo por app son ${MAX_SEATS} asientos. Para más, contacta con nosotros.` });
    }
    const { data: t } = await supabase.from('tenants')
      .select('stripe_subscription_id, subscription_status').eq('id', caller.tenant_id).maybeSingle();
    const paid = t?.subscription_status === 'active' || t?.subscription_status === 'past_due';
    if (!t?.stripe_subscription_id || !paid) {
      return reply.code(400).send({ error: 'Durante la prueba no hace falta comprar asientos; puedes añadir conductores libremente.' });
    }
    let diag;
    try {
      diag = await setSeatQuantity(caller.tenant_id, seats);
    } catch (e) {
      return reply.code(502).send({ error: `No se pudo actualizar los asientos: ${e.message}` });
    }
    await supabase.from('tenants').update({ drivers_limit: seats }).eq('id', caller.tenant_id);
    await enforceSeatLimit(caller.tenant_id); // bloquea los más nuevos si se redujo
    return reply.send({ ok: true, seats, prev: diag.prev, amount: diag.amount, charged: diag.charged, reason: diag.reason });
  });

  // Info del asiento (para el aviso de cobro ANTES de comprar): cantidad actual,
  // periodo real (month|year) y precio unitario, leídos de Stripe. Así la UI puede
  // avisar "se cobrará X/conductor de forma proporcional" con el periodo correcto.
  app.get('/api/v1/subscription/seats', async (request, reply) => {
    if (!stripe) return reply.code(500).send({ error: 'Stripe no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    const { data: t } = await supabase.from('tenants')
      .select('stripe_subscription_id, subscription_status').eq('id', caller.tenant_id).maybeSingle();
    const subId = t?.stripe_subscription_id;
    const paid = t?.subscription_status === 'active' || t?.subscription_status === 'past_due';
    if (!subId || !paid) return reply.send({ seats: null, interval: null, unit_amount: null, currency: 'eur' });
    try {
      const sub = await stripe.subscriptions.retrieve(subId, { expand: ['items.data.price'] });
      const item = sub.items?.data?.[0];
      const price = item?.price;
      const qty = item?.quantity ?? null;
      // Auto-sincroniza: los asientos PAGADOS son la cantidad de Stripe. Si la BD
      // (tenants.drivers_limit) se quedó desfasada, se corrige aquí para que tanto
      // la tarjeta como el límite de alta de conductores usen el número real.
      if (qty != null) {
        await supabase.from('tenants').update({ drivers_limit: qty })
          .eq('id', caller.tenant_id).neq('drivers_limit', qty);
      }
      return reply.send({
        seats: qty,
        interval: price?.recurring?.interval ?? null, // 'month' | 'year'
        unit_amount: price?.unit_amount ?? null,       // en céntimos
        currency: price?.currency ?? 'eur',
        cancel_at_period_end: !!sub.cancel_at_period_end,
        current_period_end: sub.current_period_end
          ? new Date(sub.current_period_end * 1000).toISOString() : null,
      });
    } catch (e) {
      return reply.code(502).send({ error: e.message });
    }
  });

  // Cancelar la suscripción a FIN DE PERIODO (no corta el servicio ya pagado):
  // el cliente sigue activo hasta current_period_end y luego no se renueva.
  // `resume:true` deshace la cancelación programada. Solo Owner.
  app.post('/api/v1/subscription/cancel', async (request, reply) => {
    if (!stripe) return reply.code(500).send({ error: 'Stripe no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (caller.role !== 'owner') return reply.code(403).send({ error: 'Solo un Owner puede cancelar la suscripción' });
    const resume = (request.body ?? {}).resume === true;
    const { data: t } = await supabase.from('tenants')
      .select('stripe_subscription_id').eq('id', caller.tenant_id).maybeSingle();
    const subId = t?.stripe_subscription_id;
    if (!subId) return reply.code(400).send({ error: 'No hay suscripción activa' });
    try {
      const sub = await stripe.subscriptions.update(subId, { cancel_at_period_end: !resume });
      return reply.send({
        ok: true,
        cancel_at_period_end: !!sub.cancel_at_period_end,
        current_period_end: sub.current_period_end
          ? new Date(sub.current_period_end * 1000).toISOString() : null,
      });
    } catch (e) {
      return reply.code(502).send({ error: `No se pudo cambiar la cancelación: ${e.message}` });
    }
  });

  // Aplicar un CUPÓN a una suscripción YA activa: el descuento se aplica a la
  // PRÓXIMA factura (la renovación) — no hace falta "adelantar" ningún pago, la
  // renovación se cobra sola con el descuento. Un uso por empresa (igual que en
  // el Checkout): se marca coupon_redeemed_code. Solo Owner.
  app.post('/api/v1/subscription/apply-coupon', async (request, reply) => {
    if (!stripe) return reply.code(500).send({ error: 'Stripe no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (caller.role !== 'owner') return reply.code(403).send({ error: 'Solo un Owner puede aplicar un cupón' });
    const code = String((request.body ?? {}).code ?? '').trim().toUpperCase();
    if (!code) return reply.code(400).send({ error: 'Código de cupón obligatorio' });

    const { data: t } = await supabase.from('tenants')
      .select('stripe_subscription_id, subscription_status, coupon_redeemed_code')
      .eq('id', caller.tenant_id).maybeSingle();
    const subId = t?.stripe_subscription_id;
    const paid = t?.subscription_status === 'active' || t?.subscription_status === 'past_due';
    if (!subId || !paid) {
      return reply.code(400).send({ error: 'Necesitas una suscripción activa; si aún no tienes, introduce el cupón al suscribirte.' });
    }
    if (t?.coupon_redeemed_code && t.coupon_redeemed_code === code) {
      return reply.code(409).send({ error: 'Ya has usado este cupón.' });
    }
    try {
      // UN solo cupón por renovación: si la suscripción ya tiene un descuento
      // pendiente (aplicado y aún no consumido por la renovación), se rechaza.
      // Ni se acumulan ni se puede cambiar por otro mejor. Tras la renovación
      // (que consume el descuento 'once'), el hueco queda libre para el año
      // siguiente.
      const sub = await stripe.subscriptions.retrieve(subId);
      const hasPending = (Array.isArray(sub.discounts) && sub.discounts.length > 0) || !!sub.discount;
      if (hasPending) {
        return reply.code(409).send({
          code: 'coupon_pending',
          error: 'Ya tienes un cupón aplicado a tu próxima renovación. Solo se puede usar un cupón por renovación.',
        });
      }
      const list = await stripe.promotionCodes.list({ code, active: true, limit: 1 });
      const promo = list.data?.[0];
      if (!promo || !promo.coupon?.valid) {
        return reply.code(404).send({ code: 'bad_coupon', error: 'Cupón no válido o caducado' });
      }
      await stripe.subscriptions.update(subId, { discounts: [{ promotion_code: promo.id }] });
      // Un uso por empresa: marcarlo canjeado (también oculta el aviso en la app).
      await supabase.from('tenants')
        .update({ coupon_redeemed_code: promo.code }).eq('id', caller.tenant_id);
      log.info(`[coupon] tenant ${caller.tenant_id}: cupón ${promo.code} aplicado a la suscripción`);
      return reply.send({ ok: true, code: promo.code, pct: Math.round(promo.coupon.percent_off || 0) });
    } catch (e) {
      return reply.code(502).send({ error: `No se pudo aplicar el cupón: ${e.message}` });
    }
  });

  // --- Stripe Checkout (Fase 4) ---
  app.post('/api/v1/create-checkout-session', async (request, reply) => {
    if (!stripe) return reply.code(500).send({ error: 'Stripe no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (caller.role !== 'owner') return reply.code(403).send({ error: 'Solo un Owner puede contratar un plan' });

    const { priceId } = request.body ?? {};
    if (!priceId) return reply.code(400).send({ error: 'priceId es obligatorio' });
    const plan = planForPrice(priceId);
    if (!plan) return reply.code(400).send({ error: 'priceId desconocido' });

    const { data: tenant } = await supabase
      .from('tenants')
      .select('stripe_customer_id, coupon_redeemed_code')
      .eq('id', caller.tenant_id)
      .single();

    const metadata = {
      tenant_id: caller.tenant_id,
      plan_id: plan.plan_id,
      drivers_limit: plan.drivers_limit === null ? 'null' : String(plan.drivers_limit),
    };

    // Cantidad = nº de conductores (asientos). Máximo MAX_SEATS: por encima, plan
    // a medida (que contacten). Modelo lineal por asiento, sin tramo plano.
    const quantity = await seatCount(caller.tenant_id);
    if (quantity > MAX_SEATS) {
      return reply.code(400).send({
        error: `El máximo por app son ${MAX_SEATS} conductores. Para más, contacta con nosotros.`,
        code: 'over_max_seats',
      });
    }

    // El plan ANUAL admite cupones (bienvenida 50% 1 vez / fidelidad 20%); el
    // cliente los introduce en el checkout. El MENSUAL es precio fijo, sin cupones.
    const isYearly = !!STRIPE_PRICE_SEAT_YEARLY && priceId === STRIPE_PRICE_SEAT_YEARLY;
    // Blindaje del cupón de bienvenida: si este tenant YA canjeó el cupón activo,
    // NO se ofrece el campo de código promocional (si no, podría re-escribirlo y
    // volver a canjearlo). Es por CÓDIGO: si el cupón activo es otro distinto, sí
    // se ofrece. Un cliente que nunca lo canjeó lo sigue teniendo.
    const activeCoupon = await readActiveCoupon();
    const alreadyRedeemed = !!(activeCoupon && tenant?.coupon_redeemed_code
      && tenant.coupon_redeemed_code === activeCoupon.code);

    try {
      const session = await stripe.checkout.sessions.create({
        mode: 'subscription',
        // adjustable_quantity: el cliente puede ajustar el nº de conductores
        // (asientos) en el propio Checkout, entre 1 y MAX_SEATS.
        line_items: [{
          price: priceId, quantity,
          adjustable_quantity: { enabled: true, minimum: 1, maximum: MAX_SEATS },
        }],
        success_url: STRIPE_SUCCESS_URL,
        cancel_url: STRIPE_CANCEL_URL,
        ...(tenant?.stripe_customer_id ? { customer: tenant.stripe_customer_id } : {}),
        ...(isYearly && !alreadyRedeemed ? { allow_promotion_codes: true } : {}),
        metadata,
        subscription_data: { metadata },
        client_reference_id: caller.tenant_id,
      });
      return reply.send({ url: session.url, id: session.id });
    } catch (e) {
      request.log.error(e);
      return reply.code(502).send({ error: 'No se pudo crear la sesión de Checkout' });
    }
  });

  // Migración de PRECIOS (#11): mueve las suscripciones ACTIVAS al Price actual
  // configurado (STRIPE_PRICE_SEAT_MONTHLY/YEARLY), respetando su intervalo. Las
  // que ya están en el precio actual se saltan. proration_behavior:'none' → el
  // precio nuevo se aplica en la PRÓXIMA factura (no cobra de golpe). Con
  // dryRun=true solo cuenta cuántas migrarían, sin tocar nada. Solo admin.
  app.post('/api/v1/admin/billing/migrate-prices', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    if (!stripe) return reply.code(400).send({ error: 'Stripe no configurado' });
    const dryRun = (request.body?.dryRun ?? request.query?.dryRun) === true
      || String(request.body?.dryRun ?? request.query?.dryRun ?? '') === 'true';
    const target = { month: STRIPE_PRICE_SEAT_MONTHLY, year: STRIPE_PRICE_SEAT_YEARLY };
    let total = 0, toMigrate = 0, migrated = 0, skipped = 0, errors = 0;
    try {
      for await (const s of stripe.subscriptions.list(
          { status: 'active', limit: 100, expand: ['data.items.data.price'] })) {
        total++;
        const item = s.items?.data?.[0];
        const interval = item?.price?.recurring?.interval; // 'month' | 'year'
        const wantPrice = interval === 'year' ? target.year : target.month;
        // Sin item, sin Price destino, o ya en el precio actual: saltar.
        if (!item || !wantPrice || item.price?.id === wantPrice) { skipped++; continue; }
        toMigrate++;
        if (dryRun) continue;
        try {
          await stripe.subscriptions.update(s.id, {
            items: [{ id: item.id, price: wantPrice }],
            proration_behavior: 'none',
          });
          migrated++;
        } catch (e) { errors++; request.log.warn(`[migrate-price] ${s.id}: ${e.message}`); }
      }
    } catch (e) {
      request.log.error(e);
      return reply.code(502).send({ error: 'No se pudo listar/migrar suscripciones' });
    }
    if (!dryRun && migrated > 0) {
      await logAdminAction(request, g.caller.id, 'migrate_prices', 'subscriptions', null,
        { total, migrated, skipped, errors });
    }
    return reply.send({ dry_run: dryRun, total, to_migrate: toMigrate, migrated, skipped, errors });
  });

  // Cupón activo para el owner: devuelve {code, pct, show}. `show` = true si hay
  // un cupón activo y este tenant NO lo ha canjeado todavía (para el aviso con
  // "copiar código" al entrar en Suscripción).
  //
  // FUENTE DE VERDAD = STRIPE. Se lee el promotion code activo real en Stripe, de
  // modo que lo que se cree/modifique/borre en Stripe se refleja en la app (y al
  // revés, porque crear/desactivar desde el panel también toca Stripe). La config
  // local solo aporta el "puntero" (promo_id que anunciamos) y la programación
  // (starts_at). Si no hay puntero válido, se AUTODESCUBRE el promo activo en
  // Stripe (preferimos el restringido al producto anual y con mayor % de dto.).
  let _annualProductId; // cache del producto del precio anual
  async function annualProductId() {
    if (_annualProductId !== undefined) return _annualProductId;
    _annualProductId = null;
    if (stripe && STRIPE_PRICE_SEAT_YEARLY) {
      try {
        const price = await stripe.prices.retrieve(STRIPE_PRICE_SEAT_YEARLY);
        _annualProductId = typeof price.product === 'string' ? price.product : (price.product?.id ?? null);
      } catch { /* sin producto */ }
    }
    return _annualProductId;
  }

  async function readActiveCoupon() {
    if (!stripe) return null;
    try {
      const cfg = await readCouponConfigRaw();
      const now = Date.now();
      // Programación: si aún no ha llegado su día, no se muestra.
      if (cfg?.starts_at && new Date(cfg.starts_at).getTime() > now) return null;

      let promo = null;
      if (cfg?.promo_id) {
        try { promo = await stripe.promotionCodes.retrieve(cfg.promo_id); } catch { promo = null; }
      }
      // Puntero ausente/obsoleto (borrado o desactivado en Stripe) -> autodescubrir.
      if (!promo || !promo.active) {
        const prod = await annualProductId();
        const list = await stripe.promotionCodes.list({ active: true, limit: 100 });
        const cand = list.data.filter((p) => p.active && p.coupon && p.coupon.valid && p.coupon.percent_off);
        // Preferir los restringidos al producto anual; luego mayor % de descuento.
        cand.sort((a, b) => {
          const ap = prod && (a.coupon.applies_to?.products || []).includes(prod) ? 1 : 0;
          const bp = prod && (b.coupon.applies_to?.products || []).includes(prod) ? 1 : 0;
          if (ap !== bp) return bp - ap;
          return (b.coupon.percent_off || 0) - (a.coupon.percent_off || 0);
        });
        promo = cand[0] || null;
      }
      if (!promo || !promo.active || !promo.coupon?.valid) return null;
      if (promo.expires_at && promo.expires_at * 1000 < now) return null;
      return {
        code: promo.code,
        pct: Math.round(promo.coupon.percent_off || 0),
        duration: promo.coupon.duration || 'once', // once | forever | repeating
        duration_in_months: promo.coupon.duration_in_months ?? null,
        coupon_id: promo.coupon.id,
        promo_id: promo.id,
        expires_at: promo.expires_at ? new Date(promo.expires_at * 1000).toISOString() : null,
        starts_at: cfg?.starts_at ?? null,
        max_redemptions: promo.max_redemptions ?? null,
      };
    } catch { return null; }
  }

  // Config crudo del cupón (incluye ids de Stripe aunque esté programado/caducado).
  async function readCouponConfigRaw() {
    try {
      const { data } = await supabase.from('system_config')
        .select('value').eq('key', 'active_coupon').maybeSingle();
      return data?.value ? JSON.parse(data.value) : null;
    } catch { return null; }
  }

  app.get('/api/v1/tenant/active-coupon', async (request, reply) => {
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    const coupon = await readActiveCoupon();
    if (!coupon) return reply.send({ show: false });
    const { data: t } = await supabase.from('tenants')
      .select('coupon_redeemed_code').eq('id', caller.tenant_id).maybeSingle();
    const redeemed = t?.coupon_redeemed_code || '';
    return reply.send({
      code: coupon.code, pct: coupon.pct, show: redeemed !== coupon.code,
      duration: coupon.duration, duration_in_months: coupon.duration_in_months,
    });
  });

  // Admin: cupón activo actual (para la pantalla de Facturación).
  app.get('/api/v1/admin/active-coupon', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    const coupon = await readActiveCoupon();
    // `config` incluye TODOS los parámetros guardados (duration, meses, máx,
    // fechas…) para poder pre-rellenar el diálogo de edición.
    const config = await readCouponConfigRaw();
    return reply.send({ coupon, config });
  });

  // Admin: DESACTIVA el cupón activo. Además de limpiar la config, desactiva el
  // promotion code en Stripe (active:false) para que NADIE lo pueda usar ya.
  app.post('/api/v1/admin/active-coupon', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    // Resuelve el promo REAL (puntero de config o autodescubierto en Stripe) para
    // desactivarlo, no solo lo que hubiera en la config local.
    const raw = await readCouponConfigRaw();
    const active = await readActiveCoupon();
    const promoId = raw?.promo_id || active?.promo_id;
    if (stripe && promoId) {
      try { await stripe.promotionCodes.update(promoId, { active: false }); }
      catch (e) { request.log.warn(`[coupon] no se pudo desactivar en Stripe: ${e.message}`); }
    }
    await supabase.from('system_config')
      .upsert({ key: 'active_coupon', value: JSON.stringify({ code: '' }) }, { onConflict: 'key' });
    await logAdminAction(request, g.caller?.id ?? null, 'active_coupon_set', 'system_config', null, { code: '' });
    return reply.send({ ok: true });
  });

  // Admin: CREA el cupón en Stripe (coupon + promotion code) y lo deja activo.
  // Opciones: pct, duration ('once'|'forever'|'repeating' + duration_in_months),
  // max_redemptions (total), starts_at (programación), expires_at (caducidad).
  // El coupon se RESTRINGE al producto del precio ANUAL (applies_to) para que solo
  // valga en el plan anual. Guarda los ids de Stripe para poder desactivarlo luego.
  app.post('/api/v1/admin/coupons', async (request, reply) => {
    const g = await adminGuard(request);
    if (g.error) return reply.code(g.code).send({ error: g.error });
    if (!stripe) return reply.code(500).send({ error: 'Stripe no configurado' });
    const body = request.body ?? {};
    const code = String(body.code || '').trim().toUpperCase();
    const pct = Number(body.pct);
    const duration = ['once', 'forever', 'repeating'].includes(body.duration) ? body.duration : 'once';
    const months = duration === 'repeating' ? Math.max(1, Number(body.duration_in_months) || 1) : null;
    const maxRedemptions = body.max_redemptions ? Number(body.max_redemptions) : null;
    const startsAt = body.starts_at || null; // ISO
    const expiresAt = body.expires_at || null; // ISO
    if (!code || !Number.isFinite(pct) || pct <= 0 || pct > 100) {
      return reply.code(400).send({ error: 'Código y porcentaje (1-100) obligatorios' });
    }
    const now = Date.now();
    const startFuture = startsAt && new Date(startsAt).getTime() > now;
    try {
      // Producto del precio anual, para restringir el cupón a ese producto.
      let productId = null;
      if (STRIPE_PRICE_SEAT_YEARLY) {
        try {
          const price = await stripe.prices.retrieve(STRIPE_PRICE_SEAT_YEARLY);
          productId = typeof price.product === 'string' ? price.product : price.product?.id;
        } catch (e) { request.log.warn(`[coupon] no se pudo leer el precio anual: ${e.message}`); }
      }
      const coupon = await stripe.coupons.create({
        percent_off: pct, duration, name: code,
        ...(months ? { duration_in_months: months } : {}),
        ...(productId ? { applies_to: { products: [productId] } } : {}),
        ...(expiresAt ? { redeem_by: Math.floor(new Date(expiresAt).getTime() / 1000) } : {}),
      });
      const promo = await stripe.promotionCodes.create({
        coupon: coupon.id, code,
        // Si empieza en el futuro, se crea INACTIVO; el cron lo activa el día fijado.
        active: !startFuture,
        ...(maxRedemptions ? { max_redemptions: maxRedemptions } : {}),
        ...(expiresAt ? { expires_at: Math.floor(new Date(expiresAt).getTime() / 1000) } : {}),
      });
      // Solo hay UN cupón vigente: al lanzar uno nuevo se RETIRA el anterior
      // (nadie más puede canjearlo). Los descuentos ya aplicados a suscripciones
      // se conservan (la caducidad/desactivación solo afecta a canjes nuevos).
      // Si el nuevo está PROGRAMADO, el anterior sigue vivo hasta que el nuevo
      // se active (el vigía lo retira entonces, vía prev_promo_id).
      const prevRaw = await readCouponConfigRaw();
      let prevPromoId = null;
      if (prevRaw?.promo_id && prevRaw.promo_id !== promo.id) {
        if (startFuture) {
          prevPromoId = prevRaw.promo_id;
        } else {
          try { await stripe.promotionCodes.update(prevRaw.promo_id, { active: false }); }
          catch (e) { request.log.warn(`[coupon] no se pudo retirar el anterior: ${e.message}`); }
        }
      }
      const value = JSON.stringify({
        code, pct, duration, duration_in_months: months, max_redemptions: maxRedemptions,
        starts_at: startsAt, expires_at: expiresAt, coupon_id: coupon.id, promo_id: promo.id,
        ...(prevPromoId ? { prev_promo_id: prevPromoId } : {}),
      });
      await supabase.from('system_config').upsert({ key: 'active_coupon', value }, { onConflict: 'key' });
      await logAdminAction(request, g.caller?.id ?? null, 'coupon_create', 'system_config', null,
        { code, pct, duration, promo_id: promo.id, product: productId });
      return reply.send({ ok: true, code, pct, promotion_code_id: promo.id, applies_to_product: productId });
    } catch (e) {
      request.log.error(e);
      return reply.code(502).send({ error: `Stripe: ${e.message}` });
    }
  });

  // Sincroniza el estado del promo code en Stripe con la programación (starts_at/
  // expires_at): lo activa cuando llega su día y lo desactiva al caducar. Lo llama
  // el vigía de semáforos (cada 15 min). Best-effort.
  async function syncScheduledCoupon() {
    if (!stripe) return;
    const raw = await readCouponConfigRaw();
    if (!raw?.promo_id) return;
    const now = Date.now();
    const started = !raw.starts_at || new Date(raw.starts_at).getTime() <= now;
    const expired = raw.expires_at && new Date(raw.expires_at).getTime() < now;
    const shouldBeActive = started && !expired;
    try {
      const promo = await stripe.promotionCodes.retrieve(raw.promo_id);
      if (promo.active !== shouldBeActive) {
        await stripe.promotionCodes.update(raw.promo_id, { active: shouldBeActive });
      }
      // Al ACTIVARSE un cupón programado, retirar el anterior (prev_promo_id):
      // el cupón vigente es único. Una sola vez (se limpia el puntero).
      if (shouldBeActive && raw.prev_promo_id) {
        try { await stripe.promotionCodes.update(raw.prev_promo_id, { active: false }); }
        catch (e) { log.warn(`[coupon-sync] retirar anterior: ${e.message}`); }
        const { prev_promo_id: _prev, ...rest } = raw;
        await supabase.from('system_config')
          .upsert({ key: 'active_coupon', value: JSON.stringify(rest) }, { onConflict: 'key' });
      }
    } catch (e) { log.warn(`[coupon-sync] ${e.message}`); }
  }

  // --- Stripe Customer Portal (Fase 4) ---
  app.post('/api/v1/create-portal-session', async (request, reply) => {
    if (!stripe) return reply.code(500).send({ error: 'Stripe no configurado' });
    const caller = await getCaller(request);
    if (!caller) return reply.code(401).send({ error: 'No autenticado' });
    if (caller.role !== 'owner') return reply.code(403).send({ error: 'Solo un Owner puede gestionar la facturación' });

    const { data: tenant } = await supabase
      .from('tenants')
      .select('stripe_customer_id')
      .eq('id', caller.tenant_id)
      .single();
    if (!tenant?.stripe_customer_id) {
      return reply.code(400).send({ error: 'No hay cliente de Stripe asociado (contrata un plan primero)' });
    }

    try {
      const session = await stripe.billingPortal.sessions.create({
        customer: tenant.stripe_customer_id,
        return_url: STRIPE_SUCCESS_URL,
      });
      return reply.send({ url: session.url });
    } catch (e) {
      request.log.error(e);
      return reply.code(502).send({ error: 'No se pudo crear la sesión del portal' });
    }
  });

  return { syncScheduledCoupon };
}
