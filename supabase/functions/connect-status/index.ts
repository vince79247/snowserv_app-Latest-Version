// Reports a provider's Stripe Connect Express status to the app (#21) so the
// payout card can show "not set up / finish setup / ready", and hands back a
// one-time Express dashboard link so a fully-onboarded provider can manage their
// bank account and view payouts. Also caches `payouts_enabled` onto the provider
// row so batch-payouts can gate on it without an API call per job.
//
// verify_jwt stays TRUE: keyed to the caller's own JWT sub.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function decodeCaller(auth: string | null): { sub?: string } {
  try {
    if (!auth) return {}
    const payload = auth.replace(/^Bearer\s+/i, '').split('.')[1]
    if (!payload) return {}
    return JSON.parse(atob(payload.replace(/-/g, '+').replace(/_/g, '/')))
  } catch {
    return {}
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const json = (b: unknown, status = 200) =>
    new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
  try {
    const caller = decodeCaller(req.headers.get('Authorization'))
    if (!caller.sub) return json({ error: 'Not authenticated' }, 401)
    const uid = caller.sub

    // Optional: ?dashboard=1 (or body {dashboard:true}) asks for a login link.
    let wantDashboard = new URL(req.url).searchParams.get('dashboard') === '1'
    if (!wantDashboard) {
      try {
        const b = await req.json()
        wantDashboard = b?.dashboard === true
      } catch { /* no body */ }
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    )
    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')!

    const { data: provider } = await supabase
      .from('providers')
      .select('id, stripe_connect_id')
      .eq('user_id', uid)
      .maybeSingle()
    if (!provider) return json({ error: 'Not a provider account' }, 403)

    const connectId: string | null = provider.stripe_connect_id
    if (!connectId) {
      return json({ connected: false, onboarded: false, payouts_enabled: false })
    }

    const acctRes = await fetch(`https://api.stripe.com/v1/accounts/${connectId}`, {
      headers: { Authorization: `Bearer ${stripeKey}` },
    })
    const acct = await acctRes.json()
    if (acct.error) throw new Error(acct.error.message)

    const payoutsEnabled = acct.payouts_enabled === true
    const onboarded = acct.details_submitted === true

    // Cache so batch-payouts can gate cheaply.
    await supabase
      .from('providers')
      .update({ payouts_enabled: payoutsEnabled })
      .eq('id', provider.id)

    let dashboardUrl: string | null = null
    if (wantDashboard && payoutsEnabled) {
      const dashRes = await fetch(
        `https://api.stripe.com/v1/accounts/${connectId}/login_links`,
        { method: 'POST', headers: { Authorization: `Bearer ${stripeKey}` } },
      )
      const dash = await dashRes.json()
      if (!dash.error) dashboardUrl = dash.url
    }

    return json({
      connected: true,
      onboarded,
      payouts_enabled: payoutsEnabled,
      dashboard_url: dashboardUrl,
    })
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    return json({ error: msg }, 500)
  }
})
