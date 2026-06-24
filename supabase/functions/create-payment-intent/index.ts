Deno.serve(async (req: Request) => {
  try {
    const { amount_cents, job_description, stripe_customer_id, payment_method_id, user_email } = await req.json()

    if (!amount_cents || amount_cents < 50) {
      return new Response(JSON.stringify({ error: 'Invalid amount' }), { status: 400 })
    }

    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')!

    let customerId = stripe_customer_id

    // Create a Stripe Customer on first payment so the card can be saved
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
    body.append('amount', String(amount_cents))
    body.append('currency', 'usd')
    body.append('payment_method_types[0]', 'card')
    body.append('description', job_description ?? 'SnowServ snow removal')
    body.append('capture_method', 'automatic')

    if (customerId) {
      body.append('customer', customerId)
      body.append('setup_future_usage', 'off_session')
    }
    if (payment_method_id) {
      body.append('payment_method', payment_method_id)
    }

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
      JSON.stringify({
        client_secret: intent.client_secret,
        stripe_customer_id: customerId,
      }),
      { headers: { 'Content-Type': 'application/json' } }
    )
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    return new Response(JSON.stringify({ error: msg }), { status: 500 })
  }
})
