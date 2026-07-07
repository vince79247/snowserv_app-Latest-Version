// CORS: the app now runs on WEB too, where the browser preflights every
// functions.invoke (Authorization header) — without these headers the call is
// blocked client-side and cancel/refund breaks in the browser.
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  try {
    const { job_id } = await req.json()
    if (!job_id) {
      return new Response(JSON.stringify({ error: 'Missing job_id' }), { status: 400, headers: cors })
    }

    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')!
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

    // Look up the payment intent ID on the job
    const jobRes = await fetch(
      `${supabaseUrl}/rest/v1/jobs?id=eq.${job_id}&select=payment_intent_id`,
      {
        headers: {
          apikey: supabaseKey,
          Authorization: `Bearer ${supabaseKey}`,
        },
      }
    )
    const jobs = await jobRes.json()
    const paymentIntentId = jobs?.[0]?.payment_intent_id

    if (!paymentIntentId) {
      return new Response(JSON.stringify({ error: 'No payment intent on file for this job' }), { status: 400, headers: cors })
    }

    // Issue full refund via Stripe
    // Look up the current payment status to decide how to reverse it.
    const piRes = await fetch(
      `https://api.stripe.com/v1/payment_intents/${paymentIntentId}`,
      { headers: { Authorization: `Bearer ${stripeKey}` } }
    )
    const pi = await piRes.json()
    if (pi.error) {
      return new Response(JSON.stringify({ error: pi.error.message }), { status: 400, headers: cors })
    }

    // Not captured yet (still just a hold) → cancel the authorization. This
    // RELEASES the hold quickly with no settled charge, so the customer isn't
    // stuck waiting 5–10 days for a refund when no provider ever accepted.
    if (
      pi.status === 'requires_capture' ||
      pi.status === 'requires_confirmation' ||
      pi.status === 'requires_payment_method'
    ) {
      const cancelRes = await fetch(
        `https://api.stripe.com/v1/payment_intents/${paymentIntentId}/cancel`,
        {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${stripeKey}`,
            'Content-Type': 'application/x-www-form-urlencoded',
          },
        }
      )
      const canceled = await cancelRes.json()
      if (canceled.error) {
        return new Response(JSON.stringify({ error: canceled.error.message }), { status: 400, headers: cors })
      }
      return new Response(
        JSON.stringify({ action: 'released', status: canceled.status }),
        { headers: { ...cors, 'Content-Type': 'application/json' } }
      )
    }

    // Hold was already released — nothing owed.
    if (pi.status === 'canceled') {
      return new Response(
        JSON.stringify({ action: 'released', status: 'canceled', already: true }),
        { headers: { ...cors, 'Content-Type': 'application/json' } }
      )
    }

    // Payment was already captured (a provider had accepted) → real refund,
    // which the bank posts back over 5–10 business days.
    const refundBody = new URLSearchParams()
    refundBody.append('payment_intent', paymentIntentId)

    const refundRes = await fetch('https://api.stripe.com/v1/refunds', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${stripeKey}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: refundBody.toString(),
    })
    const refund = await refundRes.json()

    if (refund.error) {
      return new Response(JSON.stringify({ error: refund.error.message }), { status: 400, headers: cors })
    }

    return new Response(
      JSON.stringify({ action: 'refunded', refund_id: refund.id, status: refund.status }),
      { headers: { ...cors, 'Content-Type': 'application/json' } }
    )
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    return new Response(JSON.stringify({ error: msg }), { status: 500, headers: cors })
  }
})
