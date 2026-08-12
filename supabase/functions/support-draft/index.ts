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

SERVICES & PRICING
- Prices vary by service area and are set by the admin. The LIVE numbers are
  injected below under "CURRENT LIVE FIGURES" — use ONLY those. Never quote a
  price from memory.
- Storm pricing scales the price automatically with snow depth. It is shown
  before the customer pays and eases back to normal as snow clears. The live
  bands are below.

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
- New orders go to the best-matched online provider, ranked in this order:
  equipment (shovel-only providers go last for LARGE driveways only), then current
  workload, then distance in bands, then rating among providers who are about
  equally close. Suspended providers are excluded entirely.
- There is deliberately NO distance cap — a provider willing to drive further is
  shown the distance and chooses. The offer window is below under live figures.

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

/**
 * The figures that DRIFT, read from the database on every call.
 *
 * These were hardcoded in the knowledge base above, and by 2026-08-12 every
 * single one was wrong: sidewalk was quoted at $50 against a live $80, the
 * bundle at $125 against $160, deicer as one flat $40 against a per-surface
 * $45/$70/$90, and the storm bands as 1.3/1.7/2.3 against 1.2/1.5/2.0. Those
 * numbers went into reply drafts that an admin then emailed to real people over
 * the signature "The SnowServ Team".
 *
 * Prices are per-zone and admin-editable, so ANY figure typed into a prompt is
 * a promise that decays. Same reason the FAQ screen renders storm tiers and the
 * commission from app_settings rather than from constants.
 */
async function liveFigures(supabaseUrl: string, key: string): Promise<string> {
  const h = { apikey: key, Authorization: `Bearer ${key}` }
  const money = (v: unknown) => {
    const n = Number(v)
    return Number.isFinite(n) && n > 0 ? `$${Math.round(n)}` : null
  }
  try {
    const [zonesRes, setRes] = await Promise.all([
      fetch(`${supabaseUrl}/rest/v1/service_areas?is_active=eq.true&select=*`, { headers: h }),
      fetch(`${supabaseUrl}/rest/v1/app_settings?select=key,value`, { headers: h }),
    ])
    const zones = await zonesRes.json()
    const settings = await setRes.json()
    const setting = (k: string) =>
      Array.isArray(settings) ? settings.find((s: { key: string }) => s.key === k)?.value : null

    const lines: string[] = []
    if (Array.isArray(zones) && zones.length) {
      for (const z of zones) {
        const salt = [
          money(z.price_salting_sidewalk ?? z.price_salting) &&
            `sidewalk +${money(z.price_salting_sidewalk ?? z.price_salting)}`,
          money(z.price_salting_driveway ?? z.price_salting) &&
            `driveway +${money(z.price_salting_driveway ?? z.price_salting)}`,
          money(z.price_salting) && `both +${money(z.price_salting)}`,
        ].filter(Boolean).join(' · ')
        lines.push(
          `- ${z.name}: sidewalk ${money(z.price_sidewalk) ?? 'n/a'} · ` +
          `driveway ${money(z.price_driveway) ?? 'n/a'} · ` +
          `sidewalk+driveway ${money(z.price_both) ?? 'n/a'}` +
          (salt ? `\n    deicer: ${salt}` : ''),
        )
      }
    } else {
      lines.push('- (no active service area configured — do NOT quote any price)')
    }

    let bands = 'standard pricing only'
    try {
      const parsed = JSON.parse(setting('storm_bands') ?? '')
      if (Array.isArray(parsed) && parsed.length) {
        bands = parsed
          .map((b: { min: number; mult: number }) =>
            `${b.min}"+ → ${b.mult === 1 ? 'standard' : `${b.mult}x`}`)
          .join(' · ')
      }
    } catch { /* keep the safe default */ }

    const commission = Number(setting('commission_pct'))
    const share = Number.isFinite(commission) && commission >= 0 && commission <= 100
      ? `${Math.round(100 - commission)}% to the provider (${Math.round(commission)}% platform commission)`
      : '75% to the provider (25% platform commission)'

    const timeout = Number(setting('dispatch_timeout_seconds'))
    const window = Number.isFinite(timeout) && timeout > 0
      ? (timeout % 60 === 0 ? `${timeout / 60} minutes` : `${timeout} seconds`)
      : '4 minutes'

    return [
      '\n=== CURRENT LIVE FIGURES (read from the database just now) ===',
      'These override anything above. Quote ONLY these numbers.',
      'PRICES BY SERVICE AREA:',
      ...lines,
      `STORM PRICING BANDS: ${bands}`,
      `PROVIDER SHARE: ${share}`,
      `DISPATCH OFFER WINDOW: ${window}`,
    ].join('\n')
  } catch {
    // Fail LOUD in the prompt rather than silently falling back to stale
    // numbers: a draft with no price is fixable, a draft with a wrong price
    // gets emailed to a customer.
    return '\n=== CURRENT LIVE FIGURES ===\nUNAVAILABLE — do NOT quote any price, ' +
      'fee, commission or storm multiplier in this reply. Say the team will confirm.'
  }
}

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
      `\n=== SNOWSERV KNOWLEDGE BASE ===\n${KNOWLEDGE}` +
      await liveFigures(supabaseUrl, serviceKey)

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
