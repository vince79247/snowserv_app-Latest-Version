// support-draft — the "brain" of the support Draft Assistant. An admin pastes a
// customer/provider message; this calls the Anthropic API (Claude) to write a
// reply DRAFT grounded ONLY in the SnowServ knowledge base below, then returns
// it for the admin to review + send. Human-in-the-loop: it never emails anyone.
//
// Security: verify_jwt stays ON (default), so only a logged-in user reaches this,
// AND we additionally require the caller to be an admin (profiles.is_admin) — so a
// regular customer/provider can't burn the API budget. The Anthropic key lives in
// the ANTHROPIC_API_KEY Supabase secret (never in the client).

// Cheap + capable; the admin reviews every draft, so Haiku is plenty. Bump to
// 'claude-sonnet-5' here if you ever want richer drafts (cost is still tiny).
const MODEL = 'claude-haiku-4-5-20251001'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

// SnowServ knowledge base — keep in sync with lib/screens/faq_screen.dart + the
// policies in CLAUDE.md. The model must answer ONLY from this; it must not invent
// prices, policies, or promises.
const KNOWLEDGE = `
ABOUT SNOWSERV
- On-demand snow removal marketplace (like Uber for snow). Customers request snow
  removal; nearby approved providers accept and do the job. Launching in the
  Yonkers / Westchester NY area.
- Support email: support@snowserv.app.

SERVICES & PRICING (prices vary by service area; these are the Yonkers defaults)
- Sidewalk only: $50. Driveway only: $100. Sidewalk + Driveway: $125. Deicer add-on: +$40.
- Storm pricing: when snow is deeper the price scales up automatically by snow depth
  on the ground — up to 3": standard, 3–6": 1.3x, 6–10": 1.7x, 10"+: 2.3x. It's shown
  before the customer pays and eases back to normal as snow clears.

HOW PAYMENT WORKS (very important — get this right)
- Placing an order puts a HOLD (authorization) on the card. It is NOT a charge.
- The customer is only actually CHARGED when a provider STARTS the job.
- Cancel BEFORE a provider starts → the hold is released instantly, no charge at all.
- Cancel AFTER work starts → the charge stands, but it can be refunded — contact support.
- Saved cards are handled securely by Stripe; SnowServ shows only a "card on file" chip.

CUSTOMER FLOW
- Add a service address, pick the service + optional deicer, pay (hold), a provider is
  dispatched automatically, track status in the app, rate the job after completion.
- "My Orders" shows receipts for completed jobs. Customers can order for someone else
  by entering a different service address for that order.

PROVIDER FLOW & EARNINGS
- Providers keep 75% of the job price (the platform commission is currently 25%).
- Payouts run on a 7-day rolling basis to the provider's bank via Stripe Connect.
  Providers set up their bank + identity on Stripe's secure page — SnowServ never sees
  or stores bank details or SSN, and Stripe issues the year-end 1099.
- Equipment: providers register as Shovel-only, Snowblower, or Plow-truck. This affects
  matching — large driveways prefer a snowblower or plow; shovel-only providers still get
  walkways, sidewalks, and small driveways. Providers can update their equipment anytime.
- Insurance is REQUIRED for providers who plow with a vehicle; it's OPTIONAL (but
  recommended) for shovel and snowblower providers.
- On a job: accept the dispatch, drive over, tap Start (an optional "before" photo is
  offered — recommended as dispute protection), then tap Complete (a live completion
  photo is REQUIRED as proof of work).

DISPATCH
- New orders go to the best-matched online provider (nearest + least busy, and equipment
  for large driveways). The provider has about 4 minutes to accept before it moves on.

TONE & RULES FOR YOUR REPLIES
- Warm, concise, professional. Plain language. Sign off as "The SnowServ Team".
- Answer ONLY from the facts above. If you don't know, say the team will follow up —
  do NOT invent prices, policies, timelines, or promises.
- For anything account-specific (a specific charge, refund, "where is my provider",
  a dispute, a payout question about their account): be helpful and reassuring, ask for
  the job number / details if needed, and say a team member will review and confirm.
  NEVER promise a specific refund amount or outcome — that's for a human to confirm.
- Never reveal internal/admin details or another customer's information.
`

function decodeSub(auth: string | null): string | null {
  try {
    const token = (auth ?? '').replace(/^Bearer\s+/i, '')
    const payload = JSON.parse(atob(token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')))
    return payload.sub ?? null
  } catch {
    return null
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const json = (b: unknown, status = 200) =>
    new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const anthropicKey = Deno.env.get('ANTHROPIC_API_KEY')
    if (!anthropicKey) return json({ error: 'Support assistant is not configured yet (missing ANTHROPIC_API_KEY).' }, 503)

    // ---- Auth: must be a logged-in ADMIN --------------------------------------
    const sub = decodeSub(req.headers.get('Authorization'))
    if (!sub) return json({ error: 'Not authenticated' }, 401)
    const pr = await fetch(
      `${supabaseUrl}/rest/v1/profiles?id=eq.${sub}&select=is_admin`,
      { headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` } },
    )
    const rows = await pr.json()
    if (!Array.isArray(rows) || rows[0]?.is_admin !== true) {
      return json({ error: 'Admin only' }, 403)
    }

    // ---- Input ---------------------------------------------------------------
    const { customer_message, sender_type, extra_instructions } = await req.json()
    const message = String(customer_message ?? '').trim().slice(0, 6000)
    if (!message) return json({ error: 'Paste the customer message first.' }, 400)
    const who = sender_type === 'provider' ? 'a PROVIDER' : sender_type === 'customer' ? 'a CUSTOMER' : 'a customer or provider'
    const extra = String(extra_instructions ?? '').trim().slice(0, 500)

    const system =
      `You are the support assistant for SnowServ. Write a ready-to-send email reply to ` +
      `an inbound message from ${who}. Use ONLY the knowledge base; follow its tone & rules.\n` +
      (extra ? `Extra instruction from the SnowServ team for this reply: ${extra}\n` : '') +
      `\n=== SNOWSERV KNOWLEDGE BASE ===\n${KNOWLEDGE}`

    // ---- Call Anthropic ------------------------------------------------------
    const aiRes = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'x-api-key': anthropicKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 900,
        system,
        messages: [{ role: 'user', content: `Here is the message to reply to:\n\n${message}` }],
      }),
    })
    if (!aiRes.ok) {
      const detail = await aiRes.text()
      return json({ error: 'Draft service error', detail: detail.slice(0, 300) }, 502)
    }
    const data = await aiRes.json()
    const draft = Array.isArray(data?.content)
      ? data.content.filter((c: any) => c.type === 'text').map((c: any) => c.text).join('\n').trim()
      : ''
    if (!draft) return json({ error: 'No draft produced — try again.' }, 502)

    return json({ draft })
  } catch (e: unknown) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500)
  }
})
