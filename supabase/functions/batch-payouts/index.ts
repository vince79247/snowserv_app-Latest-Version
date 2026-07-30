import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// CORS: the admin "Run Payouts" button runs in the web admin, which preflights
// functions.invoke — without this the browser blocks the call (payouts appear
// to "do nothing").
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

// Decode (NOT verify — the platform already verified via verify_jwt) the caller's
// Supabase JWT to learn who is invoking us. Returns { sub, role } or {}.
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
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const supabase = createClient(supabaseUrl, serviceKey)
    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')!

    // AUTHORIZATION: this function MOVES MONEY (Stripe transfers to providers),
    // and verify_jwt only proves the caller is logged in — so without this check
    // ANY customer or provider could trigger the whole payout run. Only an admin
    // (the "Run Payouts" button) or an internal service-role call may do this.
    const caller = decodeCaller(req.headers.get('Authorization'))
    if (caller.role !== 'service_role') {
      if (!(await isAdmin(supabaseUrl, serviceKey, caller.sub))) {
        return new Response(JSON.stringify({ error: 'Admin only' }), { status: 403, headers: cors })
      }
    }

    // Commission is admin-configurable (app_settings.commission_pct). Provider
    // keeps the rest. Falls back to 25% if unset.
    const { data: setting } = await supabase
      .from('app_settings').select('value').eq('key', 'commission_pct').maybeSingle()
    const pct = parseFloat(setting?.value ?? '25')
    const providerFraction = (100 - (isNaN(pct) ? 25 : pct)) / 100

    const cutoff = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString()

    const { data: jobs, error } = await supabase
      .from('jobs')
      .select('*, providers!jobs_provider_id_fkey!inner(id, stripe_connect_id, payouts_enabled, users!inner(name, email, id))')
      .eq('status', 'completed')
      .eq('payout_status', 'pending')
      .lt('created_at', cutoff)

    if (error) throw new Error(error.message)
    if (!jobs || jobs.length === 0) {
      return new Response(JSON.stringify({ processed: 0, message: 'No payouts due' }), {
        headers: { ...cors, 'Content-Type': 'application/json' },
      })
    }

    const results = []

    for (const job of jobs) {
      try {
        const provider = job.providers
        const payoutCents = Math.round((job.final_price ?? job.base_price) * providerFraction * 100)

        // Express model (#21): the provider onboards their own bank + identity
        // with Stripe (connect-onboard). We never see or store those details —
        // we just need a connected account that's cleared for payouts. If they
        // haven't finished onboarding, skip (they stay 'pending' for next run).
        const connectId: string | null = provider.stripe_connect_id
        if (!connectId || provider.payouts_enabled !== true) {
          results.push({ job_id: job.id, status: 'skipped', reason: 'provider payouts not set up' })
          continue
        }

        const transferBody = new URLSearchParams()
        transferBody.append('amount', String(payoutCents))
        transferBody.append('currency', 'usd')
        transferBody.append('destination', connectId)
        transferBody.append('transfer_group', `job_${job.id}`)

        const transferRes = await fetch('https://api.stripe.com/v1/transfers', {
          method: 'POST',
          headers: { Authorization: `Bearer ${stripeKey}`, 'Content-Type': 'application/x-www-form-urlencoded' },
          body: transferBody.toString(),
        })
        const transfer = await transferRes.json()
        if (transfer.error) throw new Error(`Transfer: ${transfer.error.message}`)

        await supabase.from('jobs').update({
          payout_status: 'paid',
          payout_amount: payoutCents / 100,
          stripe_transfer_id: transfer.id,
        }).eq('id', job.id)

        results.push({ job_id: job.id, status: 'paid', amount: payoutCents / 100, transfer_id: transfer.id })
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e)
        results.push({ job_id: job.id, status: 'error', reason: msg })
      }
    }

    return new Response(JSON.stringify({ processed: results.length, results }), {
      headers: { ...cors, 'Content-Type': 'application/json' },
    })
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    return new Response(JSON.stringify({ error: msg }), { status: 500, headers: cors })
  }
})
