// Lets a logged-in customer remove their saved card. The real card lives in
// Stripe's vault (a PaymentMethod attached to their Stripe customer); the
// users.card_* columns are only a display mirror for the "card on file" chip.
// So "remove" = detach the PaymentMethod from Stripe AND clear the mirror.
//
// A caller can only ever act on THEIR OWN row: we key every read/write off the
// verified JWT's `sub`, never off a client-supplied id — so no one can wipe a
// stranger's card. verify_jwt stays TRUE (default, NOT in config.toml): the
// platform rejects anonymous callers before we run; we then decode the token
// just to learn which user is asking.

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

// Decode (NOT verify — the platform already verified via verify_jwt) the caller's
// Supabase JWT to learn who is invoking us. Returns { sub } or {}.
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
  try {
    const caller = decodeCaller(req.headers.get('Authorization'))
    if (!caller.sub) {
      return new Response(JSON.stringify({ error: 'Not authenticated' }), { status: 401, headers: cors })
    }

    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')!
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

    // The caller's saved PaymentMethod id — from THEIR OWN row only.
    const userRes = await fetch(
      `${supabaseUrl}/rest/v1/users?id=eq.${caller.sub}&select=card_pm_id`,
      { headers: { apikey: supabaseKey, Authorization: `Bearer ${supabaseKey}` } }
    )
    const users = await userRes.json()
    const pmId = users?.[0]?.card_pm_id as string | undefined

    // Detach from Stripe's vault (if one's on file). Tolerate an already-gone PM
    // (resource_missing) so the call is idempotent.
    if (pmId) {
      const detachRes = await fetch(
        `https://api.stripe.com/v1/payment_methods/${pmId}/detach`,
        { method: 'POST', headers: { Authorization: `Bearer ${stripeKey}` } }
      )
      const detached = await detachRes.json()
      if (detached.error && detached.error.code !== 'resource_missing') {
        return new Response(JSON.stringify({ error: detached.error.message }), { status: 400, headers: cors })
      }
    }

    // Clear the display mirror on the user's row.
    const clearRes = await fetch(`${supabaseUrl}/rest/v1/users?id=eq.${caller.sub}`, {
      method: 'PATCH',
      headers: {
        apikey: supabaseKey,
        Authorization: `Bearer ${supabaseKey}`,
        'Content-Type': 'application/json',
        Prefer: 'return=minimal',
      },
      body: JSON.stringify({
        card_pm_id: null,
        card_last4: null,
        card_brand: null,
        card_exp_month: null,
        card_exp_year: null,
      }),
    })
    if (!clearRes.ok) {
      const t = await clearRes.text()
      return new Response(JSON.stringify({ error: `Failed to clear card: ${t}` }), { status: 500, headers: cors })
    }

    return new Response(JSON.stringify({ removed: true }), {
      headers: { ...cors, 'Content-Type': 'application/json' },
    })
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    return new Response(JSON.stringify({ error: msg }), { status: 500, headers: cors })
  }
})
