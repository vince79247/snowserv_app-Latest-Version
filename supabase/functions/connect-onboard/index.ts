// Stripe Connect EXPRESS onboarding launcher (#21). Replaces our old habit of
// collecting a provider's SSN / bank / DOB into our own database and building a
// "custom" connected account server-side. Now Stripe collects and verifies all
// of that (KYC) on its own hosted page, and files the provider's 1099 — nothing
// sensitive ever touches our DB. We store only the `stripe_connect_id`.
//
// Flow: provider taps "Set up payouts" in the app → we create (once) an Express
// account for them and return a hosted Account Link URL → the app opens it →
// Stripe walks them through bank + identity → they land back on connect-return.
//
// verify_jwt stays TRUE (default): a provider can only onboard THEMSELVES — the
// account is keyed to the caller's own JWT sub, never a client-supplied id.

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

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    )
    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')!
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!

    const { data: provider } = await supabase
      .from('providers')
      .select('id, stripe_connect_id, users!inner(email)')
      .eq('user_id', uid)
      .maybeSingle()
    if (!provider) return json({ error: 'Not a provider account' }, 403)

    const stripePost = async (path: string, form: URLSearchParams) => {
      const res = await fetch(`https://api.stripe.com/v1/${path}`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${stripeKey}`,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: form.toString(),
      })
      return res.json()
    }

    // Create the Express account once, then reuse it. We deliberately DON'T set
    // business_type or individual details — Stripe collects and verifies those
    // on its hosted page (that's the whole point). Only `transfers` is required
    // for us to pay them; 1099 filing is enabled at the platform level in the
    // Stripe dashboard.
    let connectId: string | null = provider.stripe_connect_id
    if (!connectId) {
      const acctForm = new URLSearchParams()
      acctForm.append('type', 'express')
      acctForm.append('country', 'US')
      const email = (provider.users as { email?: string })?.email
      if (email) acctForm.append('email', email)
      acctForm.append('capabilities[transfers][requested]', 'true')
      acctForm.append('business_profile[product_description]', 'Snow removal services via SnowServ')
      const acct = await stripePost('accounts', acctForm)
      if (acct.error) throw new Error(`Connect account: ${acct.error.message}`)
      connectId = acct.id
      await supabase.from('providers').update({ stripe_connect_id: connectId }).eq('id', provider.id)
    }

    // A one-time onboarding link. return_url/refresh_url both land on our owned
    // connect-return page (the mobile in-app browser needs somewhere to go).
    const ret = `${supabaseUrl}/functions/v1/connect-return`
    const linkForm = new URLSearchParams()
    linkForm.append('account', connectId!)
    linkForm.append('refresh_url', `${ret}?state=refresh`)
    linkForm.append('return_url', `${ret}?state=return`)
    linkForm.append('type', 'account_onboarding')
    const link = await stripePost('account_links', linkForm)
    if (link.error) throw new Error(`Account link: ${link.error.message}`)

    return json({ url: link.url })
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    return json({ error: msg }, 500)
  }
})
