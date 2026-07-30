import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

// Decode (NOT verify — the platform already verified via verify_jwt) the caller's
// Supabase JWT to learn who is invoking us.
function decodeCaller(auth: string | null): { sub?: string; role?: string } {
  try {
    if (!auth) return {}
    const payload = auth.replace(/^Bearer\s+/i, '').split('.')[1]
    if (!payload) return {}
    return JSON.parse(atob(payload.replace(/-/g, '+').replace(/_/g, '/')))
  } catch {
    return {}
  }
}

async function isAdmin(url: string, key: string, userId?: string): Promise<boolean> {
  if (!userId) return false
  try {
    const r = await fetch(`${url}/rest/v1/profiles?id=eq.${userId}&select=is_admin`, {
      headers: { apikey: key, Authorization: `Bearer ${key}` },
    })
    const rows = await r.json()
    return rows?.[0]?.is_admin === true
  } catch {
    return false
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  try {
    const { job_id } = await req.json()

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const supabase = createClient(supabaseUrl, serviceKey)
    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')!

    // AUTHORIZATION: this pays a provider real money. verify_jwt only proves the
    // caller is logged in, so without this ANY customer or provider could pay out
    // any job by passing its id. Only the payout cron (service role, via pg_net)
    // or an admin may call it.
    const caller = decodeCaller(req.headers.get('Authorization'))
    if (caller.role !== 'service_role') {
      if (!(await isAdmin(supabaseUrl, serviceKey, caller.sub))) {
        return new Response(JSON.stringify({ error: 'Admin only' }), { status: 403, headers: cors })
      }
    }

    // Load job + provider info
    const { data: job, error: jobErr } = await supabase
      .from('jobs')
      .select('*, providers!jobs_provider_id_fkey!inner(id, stripe_connect_id, payouts_enabled, users!inner(name, email))')
      .eq('id', job_id)
      .single()

    if (jobErr || !job) {
      return new Response(JSON.stringify({ error: 'Job not found' }), { status: 404, headers: cors })
    }

    // IDEMPOTENCY + eligibility. There was NO status guard here: calling this twice
    // transferred the provider's cut twice (it just overwrote stripe_transfer_id),
    // and an unfinished job could be paid out. Both are real money losses.
    if (job.payout_status === 'paid') {
      return new Response(
        JSON.stringify({ skipped: true, reason: 'already paid', transfer_id: job.stripe_transfer_id }),
        { headers: { ...cors, 'Content-Type': 'application/json' } },
      )
    }
    if (job.status !== 'completed') {
      return new Response(
        JSON.stringify({ error: `Job is not completed (status: ${job.status})` }),
        { status: 400, headers: cors },
      )
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
        { status: 400, headers: cors }
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
      { headers: { ...cors, 'Content-Type': 'application/json' } }
    )
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    return new Response(JSON.stringify({ error: msg }), { status: 500, headers: cors })
  }
})
