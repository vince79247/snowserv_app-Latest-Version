// Captures the authorization hold placed at order time — i.e. actually charges
// the customer — once a provider has accepted the job. Called from the provider
// app on Accept (both the dispatch card and the "Jobs Waiting" board).
//
// Idempotent: if the payment is already captured, it returns success without
// double-charging.

// CORS: the app runs on WEB too — the browser preflights functions.invoke, so
// the function must answer OPTIONS and stamp responses or the call is blocked.
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

    // Look up the payment intent ID stored on the job
    const jobRes = await fetch(
      `${supabaseUrl}/rest/v1/jobs?id=eq.${job_id}&select=payment_intent_id`,
      { headers: { apikey: supabaseKey, Authorization: `Bearer ${supabaseKey}` } }
    )
    const jobs = await jobRes.json()
    const paymentIntentId = jobs?.[0]?.payment_intent_id
    if (!paymentIntentId) {
      return new Response(
        JSON.stringify({ error: 'No payment intent on file for this job' }),
        { status: 400, headers: cors }
      )
    }

    // Check current status first
    const piRes = await fetch(
      `https://api.stripe.com/v1/payment_intents/${paymentIntentId}`,
      { headers: { Authorization: `Bearer ${stripeKey}` } }
    )
    const pi = await piRes.json()
    if (pi.error) {
      return new Response(JSON.stringify({ error: pi.error.message }), { status: 400, headers: cors })
    }

    // Already captured — nothing to do (idempotent, prevents double charge)
    if (pi.status === 'succeeded') {
      return new Response(
        JSON.stringify({ status: 'succeeded', already: true }),
        { headers: { ...cors, 'Content-Type': 'application/json' } }
      )
    }

    // Only a held payment can be captured
    if (pi.status !== 'requires_capture') {
      return new Response(
        JSON.stringify({ error: `Cannot capture — payment status is ${pi.status}` }),
        { status: 400, headers: cors }
      )
    }

    const capRes = await fetch(
      `https://api.stripe.com/v1/payment_intents/${paymentIntentId}/capture`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${stripeKey}`,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
      }
    )
    const captured = await capRes.json()
    if (captured.error) {
      return new Response(JSON.stringify({ error: captured.error.message }), { status: 400, headers: cors })
    }

    return new Response(
      JSON.stringify({ status: captured.status }),
      { headers: { ...cors, 'Content-Type': 'application/json' } }
    )
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    return new Response(JSON.stringify({ error: msg }), { status: 500, headers: cors })
  }
})
