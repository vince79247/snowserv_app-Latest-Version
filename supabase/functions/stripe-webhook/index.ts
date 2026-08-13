// Stripe webhook — the SOURCE OF TRUTH for turning a paid Checkout Session into a
// job. Fires on checkout.session.completed (the customer authorized the hold).
// Creating the job here (not on the client's return from Checkout) is what makes
// the flow robust on WEB, where the redirect reloads the app and in-memory order
// state is gone — and it still works if the customer closes the tab entirely.
//
// What it does, idempotently:
//   1. Verify the Stripe signature (STRIPE_WEBHOOK_SECRET) over the raw body.
//   2. Skip if a job already exists for this PaymentIntent (webhook retries).
//   3. Insert the address row if the customer ordered for someone else.
//   4. Insert the job (status=requested) with payment_intent_id = the HELD PI.
//      capture-payment (provider START) and refund-job (cancel) then work exactly
//      as before — the hold model is unchanged.
//   5. Mirror the saved card onto users.card_* for the "card on file" chip.
//   6. Kick dispatch immediately via the dispatch_jobs() RPC (the pg_cron that
//      runs every minute is the safety net if this call ever fails).
//
// verify_jwt MUST be false for this function (Stripe sends no Supabase JWT) — set
// in supabase/config.toml. Auth is the Stripe signature instead.

function hex(buf: ArrayBuffer): string {
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
}

// Verify the `stripe-signature` header against the raw body. Returns true/false.
async function verifyStripeSignature(
  rawBody: string,
  sigHeader: string | null,
  secret: string,
): Promise<boolean> {
  if (!sigHeader) return false
  const parts = Object.fromEntries(
    sigHeader.split(',').map((p) => p.split('=').map((s) => s.trim())),
  ) as Record<string, string>
  const t = parts['t']
  const v1 = parts['v1']
  if (!t || !v1) return false

  // Reject events older than 5 minutes (replay protection).
  const age = Math.abs(Date.now() / 1000 - Number(t))
  if (!Number.isFinite(age) || age > 300) return false

  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  const mac = await crypto.subtle.sign(
    'HMAC',
    key,
    new TextEncoder().encode(`${t}.${rawBody}`),
  )
  const expected = hex(mac)

  // Constant-time-ish comparison.
  if (expected.length !== v1.length) return false
  let diff = 0
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ v1.charCodeAt(i)
  return diff === 0
}

Deno.serve(async (req: Request) => {
  const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')!
  const webhookSecret = Deno.env.get('STRIPE_WEBHOOK_SECRET')!
  const supabaseUrl = Deno.env.get('SUPABASE_URL')!
  const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

  const rawBody = await req.text()
  const ok = await verifyStripeSignature(rawBody, req.headers.get('stripe-signature'), webhookSecret)
  if (!ok) {
    return new Response(JSON.stringify({ error: 'Invalid signature' }), { status: 400 })
  }

  let event: Record<string, any>
  try {
    event = JSON.parse(rawBody)
  } catch {
    return new Response(JSON.stringify({ error: 'Bad payload' }), { status: 400 })
  }

  // We only act on a completed Checkout Session. Any other event → 200 (ignore).
  if (event.type !== 'checkout.session.completed') {
    return new Response(JSON.stringify({ received: true }), { status: 200 })
  }

  try {
    const session = event.data.object
    const paymentIntentId: string | undefined = session.payment_intent
    const m = (session.metadata ?? {}) as Record<string, string>

    if (!paymentIntentId) {
      // Nothing we can tie a job to; ack so Stripe stops retrying.
      return new Response(JSON.stringify({ received: true, note: 'no payment_intent' }), { status: 200 })
    }

    const sbHeaders = {
      apikey: supabaseKey,
      Authorization: `Bearer ${supabaseKey}`,
      'Content-Type': 'application/json',
    }

    // (2) Idempotency — bail if a job already exists for this PaymentIntent.
    const existingRes = await fetch(
      `${supabaseUrl}/rest/v1/jobs?payment_intent_id=eq.${paymentIntentId}&select=id`,
      { headers: sbHeaders },
    )
    const existing = await existingRes.json()
    if (Array.isArray(existing) && existing.length > 0) {
      return new Response(JSON.stringify({ received: true, already: true }), { status: 200 })
    }

    // (3) Address: use the saved one, or insert the "ordering for someone else" one.
    let addressId = m.address_id
    if (m.address_mode === 'new') {
      const addrRes = await fetch(`${supabaseUrl}/rest/v1/addresses`, {
        method: 'POST',
        headers: { ...sbHeaders, Prefer: 'return=representation' },
        body: JSON.stringify({
          user_id: m.customer_id,
          address_line: m.addr_line,
          city: m.addr_city,
          state: m.addr_state,
          zip: m.addr_zip,
          // This address belongs to the ordering customer ONLY so the job can
          // reference it — it is somebody else's property, not their home. The
          // flag keeps it out of loadAddress(), which used to pick from the
          // customer's addresses with LIMIT 1 and no ORDER BY and could hand
          // back this row instead: order for your mother once, and weeks later
          // the app offers to plow her driveway when you meant your own.
          is_one_off: true,
        }),
      })
      const addr = await addrRes.json()
      addressId = Array.isArray(addr) ? addr[0]?.id : addr?.id
    }

    // (4) Insert the job with the held PaymentIntent.
    const jobBody: Record<string, unknown> = {
      status: 'requested',
      customer_id: m.customer_id,
      address_id: addressId,
      walkway: m.walkway === 'true',
      driveway: m.driveway === 'true',
      salting: m.salting === 'true',
      base_price: m.base_price != null ? Number(m.base_price) : null,
      surge_multiplier: m.surge_multiplier != null ? Number(m.surge_multiplier) : null,
      final_price: m.final_price != null ? Number(m.final_price) : null,
      payment_intent_id: paymentIntentId,
    }
    // Keep the stored shape identical to the one trigger-storm-bookings writes.
    // Without this every checkout-created job had service_type NULL.
    if (m.service_type) jobBody.service_type = m.service_type
    if (m.customer_notes) jobBody.customer_notes = m.customer_notes
    // The snow depth the storm multiplier was computed from — the evidence for
    // the price, kept with the job it priced.
    if (m.snow_level) jobBody.snow_level = Number(m.snow_level)
    // Driveway size for qualification dispatch (only present on driveway orders).
    if (m.driveway_size) jobBody.driveway_size = m.driveway_size
    if (m.job_lat) jobBody.job_lat = Number(m.job_lat)
    if (m.job_lng) jobBody.job_lng = Number(m.job_lng)
    // Sales tax Stripe Tax calculated on this order (cents → dollars). It stays with
    // the platform to remit to the state — providers are paid off the pre-tax
    // final_price, never this. $0 until a tax registration exists (pre-CoA).
    if (session.total_details && session.total_details.amount_tax != null) {
      jobBody.tax_amount = Number(session.total_details.amount_tax) / 100
    }

    const jobRes = await fetch(`${supabaseUrl}/rest/v1/jobs`, {
      method: 'POST',
      headers: { ...sbHeaders, Prefer: 'return=representation' },
      body: JSON.stringify(jobBody),
    })
    if (!jobRes.ok) {
      const errText = await jobRes.text()
      // Non-2xx → let Stripe retry (transient DB issues resolve on retry).
      return new Response(JSON.stringify({ error: 'Job insert failed', detail: errText }), { status: 500 })
    }

    // (5) Best-effort: mirror the saved card + customer onto users for the chip.
    try {
      if (m.customer_id) {
        const update: Record<string, unknown> = {}
        if (session.customer) update.stripe_customer_id = session.customer
        const piRes = await fetch(
          `https://api.stripe.com/v1/payment_intents/${paymentIntentId}?expand[]=payment_method`,
          { headers: { Authorization: `Bearer ${stripeKey}` } },
        )
        const pi = await piRes.json()
        const cardPm = pi?.payment_method
        if (cardPm?.id && cardPm.card) {
          update.card_pm_id = cardPm.id
          update.card_last4 = cardPm.card.last4
          update.card_brand = cardPm.card.brand
          update.card_exp_month = cardPm.card.exp_month
          update.card_exp_year = cardPm.card.exp_year
        }
        if (Object.keys(update).length > 0) {
          await fetch(`${supabaseUrl}/rest/v1/users?id=eq.${m.customer_id}`, {
            method: 'PATCH',
            headers: sbHeaders,
            body: JSON.stringify(update),
          })
        }
      }
    } catch (_) {
      // Card mirroring is cosmetic — never fail the webhook over it.
    }

    // (6) Immediate dispatch (cron every minute is the fallback).
    try {
      await fetch(`${supabaseUrl}/rest/v1/rpc/dispatch_jobs`, {
        method: 'POST',
        headers: sbHeaders,
        body: '{}',
      })
    } catch (_) { /* cron will pick it up */ }

    return new Response(JSON.stringify({ received: true, created: true }), { status: 200 })
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    return new Response(JSON.stringify({ error: msg }), { status: 500 })
  }
})
