import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

Deno.serve(async (req: Request) => {
  try {
    const { job_id } = await req.json()

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )
    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')!

    // Load job + provider info
    const { data: job, error: jobErr } = await supabase
      .from('jobs')
      .select('*, providers!inner(id, stripe_connect_id, payouts_enabled, users!inner(name, email))')
      .eq('id', job_id)
      .single()

    if (jobErr || !job) {
      return new Response(JSON.stringify({ error: 'Job not found' }), { status: 404 })
    }

    const provider = job.providers
    // Commission is admin-configurable (app_settings.commission_pct).
    const { data: setting } = await supabase
      .from('app_settings').select('value').eq('key', 'commission_pct').maybeSingle()
    const pct = parseFloat(setting?.value ?? '25')
    const providerFraction = (100 - (isNaN(pct) ? 25 : pct)) / 100
    const payoutCents = Math.round((job.final_price ?? job.base_price) * providerFraction * 100)

    // Express model (#21): the provider onboards bank + identity with Stripe
    // themselves (connect-onboard) — we never store those details. We only need
    // a connected account cleared for payouts.
    const connectId: string | null = provider.stripe_connect_id
    if (!connectId || provider.payouts_enabled !== true) {
      return new Response(
        JSON.stringify({ error: 'Provider has not finished payout setup' }),
        { status: 400 }
      )
    }

    // Transfer funds to provider's connected account
    const transferBody = new URLSearchParams()
    transferBody.append('amount', String(payoutCents))
    transferBody.append('currency', 'usd')
    transferBody.append('destination', connectId)
    transferBody.append('transfer_group', `job_${job_id}`)

    const transferRes = await fetch('https://api.stripe.com/v1/transfers', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${stripeKey}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: transferBody.toString(),
    })
    const transfer = await transferRes.json()
    if (transfer.error) throw new Error(`Transfer error: ${transfer.error.message}`)

    // Mark job as paid out
    await supabase.from('jobs').update({
      payout_status: 'paid',
      payout_amount: payoutCents / 100,
      stripe_transfer_id: transfer.id,
    }).eq('id', job_id)

    return new Response(
      JSON.stringify({ transfer_id: transfer.id, amount_cents: payoutCents }),
      { headers: { 'Content-Type': 'application/json' } }
    )
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    return new Response(JSON.stringify({ error: msg }), { status: 500 })
  }
})
