// CORS: the app now runs on WEB too, where the browser preflights every
// functions.invoke (Authorization header) — without these headers the call is
// blocked client-side and cancel/refund breaks in the browser.
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
      `${supabaseUrl}/rest/v1/jobs?id=eq.${job_id}&select=payment_intent_id,customer_id`,
      {
        headers: {
          apikey: supabaseKey,
          Authorization: `Bearer ${supabaseKey}`,
        },
      }
    )
    const jobs = await jobRes.json()
    const paymentIntentId = jobs?.[0]?.payment_intent_id

    if (!paymentIntentId) {
      return new Response(JSON.stringify({ error: 'No payment intent on file for this job' }), { status: 400, headers: cors })
    }

    // AUTHORIZATION: only the job's own customer (or an admin / internal service
    // call) may refund/release — otherwise any logged-in user could refund or
    // cancel a stranger's job by passing their job_id.
    const caller = decodeCaller(req.headers.get('Authorization'))
    if (caller.role !== 'service_role') {
      const customerId = jobs?.[0]?.customer_id
      let allowed = !!(caller.sub && customerId && caller.sub === customerId)
      if (!allowed) allowed = await isAdmin(supabaseUrl, supabaseKey, caller.sub)
      if (!allowed) {
        return new Response(
          JSON.stringify({ error: 'Not authorized to refund this job' }),
          { status: 403, headers: cors }
        )
      }
    }

    // Issue full refund via Stripe
    // Look up the current payment status to decide how to reverse it.
    // latest_charge is expanded so we can see whether it's ALREADY refunded —
    // without it Stripe returns just the charge id and we'd have to guess.
    const piRes = await fetch(
      `https://api.stripe.com/v1/payment_intents/${paymentIntentId}?expand[]=latest_charge`,
      { headers: { Authorization: `Bearer ${stripeKey}` } }
    )
    const pi = await piRes.json()
    if (pi.error) {
      return new Response(JSON.stringify({ error: pi.error.message }), { status: 400, headers: cors })
    }

    // Not captured yet (still just a hold) → cancel the authorization. This
    // RELEASES the hold quickly with no settled charge, so the customer isn't
    // stuck waiting 5–10 days for a refund when no provider ever accepted.
    if (
      pi.status === 'requires_capture' ||
      pi.status === 'requires_confirmation' ||
      pi.status === 'requires_payment_method'
    ) {
      const cancelRes = await fetch(
        `https://api.stripe.com/v1/payment_intents/${paymentIntentId}/cancel`,
        {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${stripeKey}`,
            'Content-Type': 'application/x-www-form-urlencoded',
          },
        }
      )
      const canceled = await cancelRes.json()
      if (canceled.error) {
        return new Response(JSON.stringify({ error: canceled.error.message }), { status: 400, headers: cors })
      }
      return new Response(
        JSON.stringify({ action: 'released', status: canceled.status }),
        { headers: { ...cors, 'Content-Type': 'application/json' } }
      )
    }

    // Hold was already released — nothing owed.
    if (pi.status === 'canceled') {
      return new Response(
        JSON.stringify({ action: 'released', status: 'canceled', already: true }),
        { headers: { ...cors, 'Content-Type': 'application/json' } }
      )
    }

    // Charge was already refunded — report SUCCESS, not an error.
    //
    // This branch exists because its absence was a trap. The admin UI only marks
    // the job cancelled (which is what hides the Refund button) AFTER this
    // function returns OK. Returning 400 here meant a job whose money had already
    // been returned kept its Refund button forever, failing identically on every
    // press, with no way for an admin to clear it. Refunding is idempotent from
    // the caller's point of view: the desired end state — customer made whole —
    // is already true, so say so. Mirrors the `canceled` branch above.
    const charge = (pi.latest_charge && typeof pi.latest_charge === 'object')
      ? pi.latest_charge
      : null
    if (charge?.refunded === true) {
      return new Response(
        JSON.stringify({ action: 'refunded', status: 'succeeded', already: true }),
        { headers: { ...cors, 'Content-Type': 'application/json' } }
      )
    }

    // Payment was already captured (a provider had accepted) → real refund,
    // which the bank posts back over 5–10 business days.
    const refundBody = new URLSearchParams()
    refundBody.append('payment_intent', paymentIntentId)

    const refundRes = await fetch('https://api.stripe.com/v1/refunds', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${stripeKey}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: refundBody.toString(),
    })
    const refund = await refundRes.json()

    if (refund.error) {
      // Belt-and-braces for the same case: a refund raced in between our read
      // above and this write, or the charge was refunded outside the app
      // (straight from the Stripe dashboard, which is exactly what an admin
      // does when the button is broken). Still the desired end state.
      if (refund.error.code === 'charge_already_refunded') {
        return new Response(
          JSON.stringify({ action: 'refunded', status: 'succeeded', already: true }),
          { headers: { ...cors, 'Content-Type': 'application/json' } }
        )
      }
      return new Response(JSON.stringify({ error: refund.error.message }), { status: 400, headers: cors })
    }

    return new Response(
      JSON.stringify({ action: 'refunded', refund_id: refund.id, status: refund.status }),
      { headers: { ...cors, 'Content-Type': 'application/json' } }
    )
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    return new Response(JSON.stringify({ error: msg }), { status: 500, headers: cors })
  }
})
