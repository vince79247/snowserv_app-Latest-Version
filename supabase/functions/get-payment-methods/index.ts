Deno.serve(async (req: Request) => {
  try {
    const { stripe_customer_id } = await req.json()

    if (!stripe_customer_id) {
      return new Response(JSON.stringify({ cards: [] }), {
        headers: { 'Content-Type': 'application/json' },
      })
    }

    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')!

    const response = await fetch(
      `https://api.stripe.com/v1/payment_methods?customer=${stripe_customer_id}&type=card&limit=5`,
      {
        headers: { Authorization: `Bearer ${stripeKey}` },
      }
    )

    const result = await response.json()

    if (result.error) {
      return new Response(JSON.stringify({ cards: [] }), {
        headers: { 'Content-Type': 'application/json' },
      })
    }

    const cards = (result.data ?? []).map((pm: Record<string, any>) => ({
      id: pm.id,
      last4: pm.card.last4,
      brand: pm.card.brand,
      exp_month: pm.card.exp_month,
      exp_year: pm.card.exp_year,
    }))

    return new Response(JSON.stringify({ cards }), {
      headers: { 'Content-Type': 'application/json' },
    })
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    return new Response(JSON.stringify({ error: msg, cards: [] }), { status: 500 })
  }
})
