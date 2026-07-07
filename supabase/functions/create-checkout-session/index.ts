// Creates a Stripe Checkout Session for a snow-removal order and returns the
// hosted payment-page URL. Replaces the old flutter_stripe custom PaymentIntent
// flow so the SAME code path works on iOS, Android AND web (Mac/Windows are
// served by the web app in a browser) — and it gets Apple Pay / Google Pay for
// free on the hosted page.
//
// AUTHORIZE-AND-CAPTURE IS PRESERVED: the session is created with
// payment_intent_data[capture_method]=manual, so completing the page places an
// authorization HOLD (PaymentIntent in requires_capture), NOT a charge. The
// underlying object is still a normal PaymentIntent, so capture-payment (on
// provider START) and refund-job (release/refund on cancel) carry over unchanged
// — the webhook grabs session.payment_intent and stores it on the job like before.
//
// The job row is NOT created here. All the fields needed to create it ride in the
// session metadata and the stripe-webhook function inserts the job (+ address for
// "ordering for someone else") only after payment is confirmed — robust across the
// web redirect / a closed tab.

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: cors })
  }
  try {
    const {
      amount_cents,
      job_description,
      stripe_customer_id,
      user_email,
      success_url,
      cancel_url,
      metadata,
    } = await req.json()

    if (!amount_cents || amount_cents < 50) {
      return new Response(JSON.stringify({ error: 'Invalid amount' }), {
        status: 400,
        headers: { ...cors, 'Content-Type': 'application/json' },
      })
    }
    if (!success_url || !cancel_url) {
      return new Response(JSON.stringify({ error: 'Missing return URLs' }), {
        status: 400,
        headers: { ...cors, 'Content-Type': 'application/json' },
      })
    }

    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')!

    // Create a Stripe Customer on first order so Checkout can save the card and
    // show it back to returning customers (and so wallets remember them).
    let customerId = stripe_customer_id
    if (!customerId && user_email) {
      const customerBody = new URLSearchParams()
      customerBody.append('email', user_email)
      customerBody.append('metadata[source]', 'snowserv')
      const customerRes = await fetch('https://api.stripe.com/v1/customers', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${stripeKey}`,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: customerBody.toString(),
      })
      const customer = await customerRes.json()
      if (customer.error) throw new Error(customer.error.message)
      customerId = customer.id
    }

    const body = new URLSearchParams()
    body.append('mode', 'payment')
    body.append('success_url', success_url)
    body.append('cancel_url', cancel_url)

    // Single line item priced at the exact order total (server trusts the amount
    // the app computed from the matched zone, same as the old flow).
    body.append('line_items[0][quantity]', '1')
    body.append('line_items[0][price_data][currency]', 'usd')
    body.append('line_items[0][price_data][unit_amount]', String(amount_cents))
    body.append('line_items[0][price_data][product_data][name]', job_description ?? 'SnowServ snow removal')

    // THE HOLD: manual capture → authorization only, captured later on provider START.
    body.append('payment_intent_data[capture_method]', 'manual')
    body.append('payment_intent_data[description]', job_description ?? 'SnowServ snow removal')

    // Reinforce the hold promise ON Stripe's hosted page (a line near the Pay
    // button), so it matches the app's order-screen note. Must stay consistent
    // with the authorize-and-capture model — charged only on provider START.
    body.append(
      'custom_text[submit][message]',
      'This places a hold — your card is only charged when a provider starts your job.',
    )

    if (customerId) {
      body.append('customer', customerId)
      // Save the card to the customer so it's offered on the next order.
      body.append('payment_intent_data[setup_future_usage]', 'off_session')
    }

    // Everything the webhook needs to create the job after payment confirms.
    // Stripe metadata values are strings (max 500 chars each).
    if (metadata && typeof metadata === 'object') {
      for (const [k, v] of Object.entries(metadata)) {
        if (v === null || v === undefined) continue
        body.append(`metadata[${k}]`, String(v).slice(0, 500))
      }
    }

    const response = await fetch('https://api.stripe.com/v1/checkout/sessions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${stripeKey}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: body.toString(),
    })
    const session = await response.json()
    if (session.error) {
      return new Response(JSON.stringify({ error: session.error.message }), {
        status: 400,
        headers: { ...cors, 'Content-Type': 'application/json' },
      })
    }

    return new Response(
      JSON.stringify({
        url: session.url,
        session_id: session.id,
        stripe_customer_id: customerId,
      }),
      { headers: { ...cors, 'Content-Type': 'application/json' } }
    )
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    return new Response(JSON.stringify({ error: msg }), {
      status: 500,
      headers: { ...cors, 'Content-Type': 'application/json' },
    })
  }
})
