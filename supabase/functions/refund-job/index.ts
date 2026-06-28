Deno.serve(async (req: Request) => {
  try {
    const { job_id } = await req.json()
    if (!job_id) {
      return new Response(JSON.stringify({ error: 'Missing job_id' }), { status: 400 })
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
      return new Response(JSON.stringify({ error: 'No payment intent on file for this job' }), { status: 400 })
    }

    // Issue full refund via Stripe
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
      return new Response(JSON.stringify({ error: refund.error.message }), { status: 400 })
    }

    return new Response(
      JSON.stringify({ refund_id: refund.id, status: refund.status }),
      { headers: { 'Content-Type': 'application/json' } }
    )
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    return new Response(JSON.stringify({ error: msg }), { status: 500 })
  }
})
