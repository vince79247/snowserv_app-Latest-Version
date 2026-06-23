Deno.serve(async (req: Request) => {
  try {
    const { amount_cents, job_description } = await req.json()

    if (!amount_cents || amount_cents < 50) {
      return new Response(JSON.stringify({ error: 'Invalid amount' }), { status: 400 })
    }

    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')!

    const body = new URLSearchParams()
    body.append('amount', String(amount_cents))
    body.append('currency', 'usd')
    body.append('payment_method_types[0]', 'card')
    body.append('description', job_description ?? 'SnowServ snow removal')
    body.append('capture_method', 'automatic')

    const response = await fetch('https://api.stripe.com/v1/payment_intents', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${stripeKey}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: body.toString(),
    })

    const intent = await response.json()

    if (intent.error) {
      return new Response(JSON.stringify({ error: intent.error.message }), { status: 400 })
    }

    return new Response(
      JSON.stringify({ client_secret: intent.client_secret }),
      { headers: { 'Content-Type': 'application/json' } }
    )
  } catch (e: any) {
    return new Response(JSON.stringify({ error: e.message }), { status: 500 })
  }
})
