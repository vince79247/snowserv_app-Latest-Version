// Captures the authorization hold placed at order time — i.e. actually charges
// the customer — when a provider STARTS the job (markInProgress → in_progress),
// NOT on Accept. The payment stays a hold through requested/assigned so a
// customer who cancels before work begins gets an instant hold release (see
// refund-job), never a charge-then-refund. Accept does not call this.
//
// Idempotent: if the payment is already captured, it returns success without
// double-charging (so a post-start re-dispatch never double-charges the card).

// CORS: the app runs on WEB too — the browser preflights functions.invoke, so
// the function must answer OPTIONS and stamp responses or the call is blocked.
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
    const { job_id } = await req.json()
    if (!job_id) {
      return new Response(JSON.stringify({ error: 'Missing job_id' }), { status: 400, headers: cors })
    }

    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')!
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

    // Look up the payment intent + who the job belongs to.
    const jobRes = await fetch(
      `${supabaseUrl}/rest/v1/jobs?id=eq.${job_id}&select=payment_intent_id,provider_id`,
      { headers: { apikey: supabaseKey, Authorization: `Bearer ${supabaseKey}` } }
    )
    const jobs = await jobRes.json()
    const paymentIntentId = jobs?.[0]?.payment_intent_id
    if (!paymentIntentId) {
      return new Response(
        JSON.stringify({ error: 'No payment intent on file for this job' }),
        { status: 400, headers: cors }
      )
    }

    // AUTHORIZATION: only the job's assigned provider (or an admin / internal
    // service call) may capture — otherwise any logged-in user could charge a
    // stranger's card by passing their job_id.
    const caller = decodeCaller(req.headers.get('Authorization'))
    if (caller.role !== 'service_role') {
      let allowed = false
      const providerId = jobs?.[0]?.provider_id
      if (providerId && caller.sub) {
        const pr = await fetch(
          `${supabaseUrl}/rest/v1/providers?id=eq.${providerId}&select=user_id`,
          { headers: { apikey: supabaseKey, Authorization: `Bearer ${supabaseKey}` } }
        )
        const prov = await pr.json()
        if (prov?.[0]?.user_id && prov[0].user_id === caller.sub) allowed = true
      }
      if (!allowed) allowed = await isAdmin(supabaseUrl, supabaseKey, caller.sub)
      if (!allowed) {
        return new Response(
          JSON.stringify({ error: 'Not authorized to capture this job' }),
          { status: 403, headers: cors }
        )
      }
    }

    // Check current status first
    const piRes = await fetch(
      `https://api.stripe.com/v1/payment_intents/${paymentIntentId}`,
      { headers: { Authorization: `Bearer ${stripeKey}` } }
    )
    const pi = await piRes.json()
    if (pi.error) {
      return new Response(JSON.stringify({ error: pi.error.message }), { status: 400, headers: cors })
    }

    // Already captured — nothing to do (idempotent, prevents double charge)
    if (pi.status === 'succeeded') {
      return new Response(
        JSON.stringify({ status: 'succeeded', already: true }),
        { headers: { ...cors, 'Content-Type': 'application/json' } }
      )
    }

    // Only a held payment can be captured
    if (pi.status !== 'requires_capture') {
      return new Response(
        JSON.stringify({ error: `Cannot capture — payment status is ${pi.status}` }),
        { status: 400, headers: cors }
      )
    }

    const capRes = await fetch(
      `https://api.stripe.com/v1/payment_intents/${paymentIntentId}/capture`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${stripeKey}`,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
      }
    )
    const captured = await capRes.json()
    if (captured.error) {
      return new Response(JSON.stringify({ error: captured.error.message }), { status: 400, headers: cors })
    }

    return new Response(
      JSON.stringify({ status: captured.status }),
      { headers: { ...cors, 'Content-Type': 'application/json' } }
    )
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    return new Response(JSON.stringify({ error: msg }), { status: 500, headers: cors })
  }
})
