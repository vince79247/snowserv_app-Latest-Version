// Creates a Stripe Checkout Session for a snow-removal order and returns the
// hosted payment-page URL. Replaces the old flutter_stripe custom PaymentIntent
// flow so the SAME code path works on iOS, Android AND web — and it gets Apple
// Pay / Google Pay for free on the hosted page.
//
// AUTHORIZE-AND-CAPTURE IS PRESERVED: the session is created with
// payment_intent_data[capture_method]=manual, so completing the page places an
// authorization HOLD (PaymentIntent in requires_capture), NOT a charge. The
// underlying object is still a normal PaymentIntent, so capture-payment (provider
// START) and refund-job (release/refund on cancel) carry over unchanged.
//
// The job row is NOT created here. The fields the webhook needs to insert it ride
// in the session metadata, and stripe-webhook creates the job only after payment
// is confirmed — robust across the web redirect / a closed tab.
//
// SECURITY — the SERVER is authoritative on price and identity. verify_jwt stays
// TRUE (default; not in config.toml). We NEVER trust a client-supplied amount or
// price: we recompute base_price / surge / final_price from the matched pricing
// zone, the saved address's price_multiplier, and live snow depth — the same logic
// the app shows the customer. We also force customer_id to the authenticated
// caller (and verify a saved address_id belongs to them), so an order can't be
// priced at $0.50 or billed to another user by tampering with the request.

import { priceOrder } from '../_shared/pricing.ts'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

// ---- auth: read the caller from the platform-verified JWT ------------------
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

// ---- geofence matching (ported from lib/utils/geo.dart) --------------------
type Pt = { lat: number; lng: number }
function parsePolygon(raw: unknown): Pt[] {
  if (!Array.isArray(raw)) return []
  const out: Pt[] = []
  for (const v of raw) {
    const lat = Number((v as Record<string, unknown>)?.lat)
    const lng = Number((v as Record<string, unknown>)?.lng)
    if (Number.isFinite(lat) && Number.isFinite(lng)) out.push({ lat, lng })
  }
  return out
}
function pointInPolygon(lat: number, lng: number, poly: Pt[]): boolean {
  if (poly.length < 3) return false
  let inside = false
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const yi = poly[i].lat, xi = poly[i].lng
    const yj = poly[j].lat, xj = poly[j].lng
    const intersects = ((yi > lat) !== (yj > lat)) &&
      (lng < ((xj - xi) * (lat - yi)) / (yj - yi) + xi)
    if (intersects) inside = !inside
  }
  return inside
}
// Unsigned shoelace area, squared-degree units — only used to compare
// overlapping zones (smaller = more specific). Must match geo.dart::polygonArea.
function polygonArea(poly: Pt[]): number {
  if (poly.length < 3) return 0
  let sum = 0
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    sum += poly[j].lng * poly[i].lat - poly[i].lng * poly[j].lat
  }
  return Math.abs(sum) / 2
}
// Keep IN LOCKSTEP with geo.dart::matchZone: among every zone whose polygon
// contains the point, the SMALLEST-area one wins (a premium pocket drawn on top
// of a larger zone takes precedence), order-independent. ZIP is a fallback only
// for polygon-less zones or a failed geocode.
function matchZone(
  lat: number | null,
  lng: number | null,
  zip: string | null,
  zones: Record<string, any>[],
): Record<string, any> | null {
  if (lat != null && lng != null) {
    let best: Record<string, any> | null = null
    let bestArea = Infinity
    for (const zone of zones) {
      const poly = parsePolygon(zone.polygon)
      if (poly.length === 0 || !pointInPolygon(lat, lng, poly)) continue
      const area = polygonArea(poly)
      if (area < bestArea) {
        bestArea = area
        best = zone
      }
    }
    if (best) return best
  }
  if (zip) {
    for (const zone of zones) {
      const hasPolygon = parsePolygon(zone.polygon).length > 0
      if (lat != null && lng != null && hasPolygon) continue
      const zips = (zone.zips as unknown[] | null)?.map((z) => String(z)) ?? []
      if (zips.includes(zip)) return zone
    }
  }
  return null
}

// ---- storm pricing ---------------------------------------------------------
// The snow-depth -> multiplier ladder. Default = the Yonkers launch ladder; the
// live value is admin-editable in app_settings.storm_bands, which the Flutter
// client (AppConfig.stormBands) reads too — so the price shown always equals the
// price charged. Both sides validate identically and fall back to this default.
type StormBand = { min: number; mult: number }
const DEFAULT_STORM_BANDS: StormBand[] = [
  { min: 0, mult: 1.0 },
  { min: 3, mult: 1.3 },
  { min: 6, mult: 1.7 },
  { min: 10, mult: 2.3 },
]

// Read + validate app_settings.storm_bands. Any problem → the default ladder, so
// a bad stored value can never break checkout. Mirror of AppConfig.parseStormBands.
async function loadStormBands(
  supabaseUrl: string,
  dbHeaders: Record<string, string>,
): Promise<StormBand[]> {
  try {
    const r = await fetch(
      `${supabaseUrl}/rest/v1/app_settings?key=eq.storm_bands&select=value`,
      { headers: dbHeaders },
    )
    const rows = await r.json()
    const raw = Array.isArray(rows) && rows[0]?.value
    if (!raw) return DEFAULT_STORM_BANDS
    const parsed = JSON.parse(raw)
    if (!Array.isArray(parsed) || parsed.length === 0) return DEFAULT_STORM_BANDS
    const bands: StormBand[] = []
    for (const item of parsed) {
      const min = Number(item?.min)
      const mult = Number(item?.mult)
      if (!Number.isFinite(min) || !Number.isFinite(mult)) return DEFAULT_STORM_BANDS
      if (min < 0 || mult < 1.0 || mult > 5.0) return DEFAULT_STORM_BANDS
      bands.push({ min, mult })
    }
    bands.sort((a, b) => a.min - b.min)
    if (bands[0].min !== 0) return DEFAULT_STORM_BANDS
    for (let i = 1; i < bands.length; i++) {
      if (bands[i].min <= bands[i - 1].min) return DEFAULT_STORM_BANDS
    }
    return bands
  } catch {
    return DEFAULT_STORM_BANDS
  }
}

async function surgeForPoint(
  lat: number | null,
  lng: number | null,
  bands: StormBand[],
): Promise<{ mult: number; inches: number | null }> {
  if (lat == null || lng == null) return { mult: 1.0, inches: null }
  try {
    const url =
      `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lng}&current=snow_depth&timezone=auto`
    const r = await fetch(url).then((r) => r.json())
    const meters = Number(r?.current?.snow_depth ?? 0)
    const inches = (Number.isFinite(meters) ? meters : 0) * 39.3701
    let mult = 1.0
    for (const b of bands) if (inches >= b.min) mult = b.mult
    // Hand back the DEPTH as well as the multiplier. It gets stored on the job
    // (jobs.snow_level) and printed on the receipt, so "why was I charged 1.5x"
    // has an answer with a number in it instead of our word against theirs.
    return { mult, inches }
  } catch {
    // No storm data → base price. Never over- or under-charge on a fetch error,
    // and record no depth rather than a fake 0 that would read as "we measured
    // zero inches" on a receipt.
    return { mult: 1.0, inches: null }
  }
}

// ---- geocoding (ported from lib/utils/geocode.dart) ------------------------
// PRIMARY = US Census Bureau geocoder: free, keyless, and it PERMITS
// server/datacenter use. Nominatim blocks datacenter IPs, so it failed here on
// every real order (found 2026-07-29 on job #1178) — which silently forced surge
// to 1.0x and left job_lat null. Nominatim stays as a fallback only.
// Keep this chain in lockstep with lib/utils/geocode.dart: if the two sides
// resolve an address differently they can pick different zones near a boundary,
// and the shown price would stop matching the charged price.
async function geocode(a: {
  address_line?: string; city?: string; state?: string; zip?: string
}): Promise<{ lat: number; lng: number } | null> {
  const oneLine =
    `${a.address_line ?? ''}, ${a.city ?? ''}, ${a.state ?? ''} ${a.zip ?? ''}`
  return (await geocodeCensus(oneLine)) ?? (await geocodeNominatim(oneLine))
}

async function geocodeCensus(oneLine: string): Promise<{ lat: number; lng: number } | null> {
  try {
    const res = await fetch(
      'https://geocoding.geo.census.gov/geocoder/locations/onelineaddress' +
        `?address=${encodeURIComponent(oneLine)}&benchmark=Public_AR_Current&format=json`,
      { signal: AbortSignal.timeout(6000) },
    )
    if (!res.ok) return null
    const j = await res.json()
    const m = j?.result?.addressMatches
    if (Array.isArray(m) && m.length > 0) {
      const lat = Number(m[0]?.coordinates?.y)
      const lng = Number(m[0]?.coordinates?.x)
      if (Number.isFinite(lat) && Number.isFinite(lng)) return { lat, lng }
    }
  } catch { /* fall through */ }
  return null
}

async function geocodeNominatim(oneLine: string): Promise<{ lat: number; lng: number } | null> {
  try {
    const res = await fetch(
      `https://nominatim.openstreetmap.org/search?q=${encodeURIComponent(oneLine)}&format=json&limit=1`,
      { headers: { 'User-Agent': 'SnowServApp/1.0' } },
    )
    if (!res.ok) return null
    const j = await res.json()
    if (Array.isArray(j) && j.length > 0) {
      return { lat: Number(j[0].lat), lng: Number(j[0].lon) }
    }
  } catch { /* fall through */ }
  return null
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const json = (b: unknown, status = 200) =>
    new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

  try {
    const caller = decodeCaller(req.headers.get('Authorization'))
    if (!caller.sub) return json({ error: 'Not authenticated' }, 401)
    const uid = caller.sub

    const {
      job_description,
      stripe_customer_id,
      user_email,
      success_url,
      cancel_url,
      metadata: rawMeta,
    } = await req.json()
    if (!success_url || !cancel_url) return json({ error: 'Missing return URLs' }, 400)

    const md: Record<string, any> = (rawMeta && typeof rawMeta === 'object') ? rawMeta : {}

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')!
    const dbHeaders = { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` }

    // ---- Resolve the requested services -----------------------------------
    const wantsWalkway = String(md.walkway) === 'true'
    const wantsDriveway = String(md.driveway) === 'true'
    const wantsSalting = String(md.salting) === 'true'
    if (!wantsWalkway && !wantsDriveway) return json({ error: 'No service selected' }, 400)

    // ---- Resolve the service address (authoritatively) --------------------
    let addr: { address_line?: string; city?: string; state?: string; zip?: string }
    let multiplier = 1.0
    if (String(md.address_mode) === 'saved') {
      // Must be the CALLER'S OWN saved address — prevents pricing off someone
      // else's multiplier or attaching a foreign address_id.
      const r = await fetch(
        `${supabaseUrl}/rest/v1/addresses?id=eq.${md.address_id}&user_id=eq.${uid}` +
          `&select=address_line,city,state,zip,price_multiplier`,
        { headers: dbHeaders })
      const rows = await r.json()
      if (!Array.isArray(rows) || rows.length === 0) {
        return json({ error: 'Address not found' }, 400)
      }
      addr = rows[0]
      multiplier = Number(rows[0].price_multiplier) || 1.0
    } else {
      // "Ordering for someone else" — a brand-new address, always multiplier 1.0.
      addr = {
        address_line: md.addr_line, city: md.addr_city,
        state: md.addr_state, zip: md.addr_zip,
      }
      if (!addr.address_line || !addr.zip) return json({ error: 'Incomplete address' }, 400)
    }

    // ---- Match the pricing zone (server geocodes; never trusts client lat/lng)
    const geo = await geocode(addr)
    const zonesRes = await fetch(
      `${supabaseUrl}/rest/v1/service_areas?is_active=eq.true&select=*`, { headers: dbHeaders })
    const zones = await zonesRes.json()
    const zone = matchZone(geo?.lat ?? null, geo?.lng ?? null, addr.zip ?? null,
      Array.isArray(zones) ? zones : [])
    if (!zone) return json({ error: 'Not available in your area yet' }, 400)

    // ---- Compute the price (the same module the app prices with) ----------
    // Shared with lib/utils/pricing.dart and verified against the same cases
    // in test/pricing_cases.json, so what the customer was SHOWN and what they
    // are CHARGED cannot drift apart silently. This used to be a hand-copied
    // duplicate kept in sync by a comment.
    const stormBands = await loadStormBands(supabaseUrl, dbHeaders)
    const storm = await surgeForPoint(geo?.lat ?? null, geo?.lng ?? null, stormBands)
    const priced = priceOrder({
      zone,
      wantsWalkway,
      wantsDriveway,
      wantsSalting,
      addressMultiplier: multiplier,
      surge: storm.mult,
    })
    const baseTotal = priced.base
    const surge = priced.surge
    const finalPrice = priced.finalPrice
    const amountCents = finalPrice * 100
    if (!Number.isFinite(amountCents) || amountCents < 50) {
      return json({ error: 'Could not price this order' }, 400)
    }

    // ---- Server-authoritative metadata for the webhook --------------------
    // Start from what the client sent (service flags, notes, address), then
    // OVERRIDE every price/identity field with the values we just computed.
    const meta: Record<string, string> = {}
    for (const [k, v] of Object.entries(md)) {
      if (v === null || v === undefined) continue
      meta[k] = String(v).slice(0, 500)
    }
    meta.customer_id = uid                       // force caller identity
    meta.base_price = String(baseTotal)
    meta.surge_multiplier = String(surge)
    meta.final_price = String(finalPrice)
    // The measured snow depth behind that multiplier, in inches, at the JOB's
    // coordinates. Stored on the job and printed on the receipt so a storm-
    // pricing question is settled by a recorded number and a named source
    // rather than by argument. Omitted (not zeroed) when the lookup failed.
    if (storm.inches != null) meta.snow_level = storm.inches.toFixed(1)
    // job_lat/lng drive DISPATCH proximity + the on-site verification chips —
    // never the price (that's `zone` + `surge`, both computed from our own
    // geocode above). So: prefer our server geocode; if it failed, fall back to
    // the coordinates the CLIENT geocoded rather than dropping them, which used
    // to leave every job unverifiable. Client values are only trusted for these
    // two non-financial uses, and only if they're sane numbers.
    if (geo) {
      meta.job_lat = String(geo.lat)
      meta.job_lng = String(geo.lng)
    } else {
      const cLat = Number(meta.job_lat), cLng = Number(meta.job_lng)
      const sane = Number.isFinite(cLat) && Number.isFinite(cLng) &&
        Math.abs(cLat) <= 90 && Math.abs(cLng) <= 180 && (cLat !== 0 || cLng !== 0)
      if (!sane) { delete meta.job_lat; delete meta.job_lng }
    }

    // ---- Stripe customer (so the card can be saved + offered next time) ----
    let customerId = stripe_customer_id
    if (!customerId && user_email) {
      const cb = new URLSearchParams()
      cb.append('email', user_email)
      cb.append('metadata[source]', 'snowserv')
      const cr = await fetch('https://api.stripe.com/v1/customers', {
        method: 'POST',
        headers: { Authorization: `Bearer ${stripeKey}`, 'Content-Type': 'application/x-www-form-urlencoded' },
        body: cb.toString(),
      })
      const customer = await cr.json()
      if (customer.error) throw new Error(customer.error.message)
      customerId = customer.id
    }

    // ---- Tax location = WHERE THE SNOW IS, not where the card is billed ----
    // New York taxes snow removal as maintenance of real property, and a service
    // performed on real property is sourced to the property — so a Yonkers
    // driveway is taxed at the Yonkers rate even when the payer's card bills to
    // another state. That case is not hypothetical: "ordering for someone else"
    // exists precisely so an out-of-town child can clear a parent's driveway,
    // and billing-address sourcing would tax that at the child's address.
    //
    // Stripe picks the shipping address first and falls back to billing. We have
    // neither by default, so it was using whatever billing address got typed on
    // the Checkout page. Writing the SERVICE address onto the customer, and
    // setting customer_update[address]=never below so the typed one cannot
    // override it, makes Stripe source tax from the property.
    //
    // Harmless today — with no tax registration Stripe computes $0 either way —
    // which is exactly why this is the right moment to fix it, before the
    // Certificate of Authority makes it real money.
    if (customerId && addr) {
      const ab = new URLSearchParams()
      ab.append('address[line1]', String(addr.address_line ?? ''))
      ab.append('address[city]', String(addr.city ?? ''))
      ab.append('address[state]', String(addr.state ?? ''))
      ab.append('address[postal_code]', String(addr.zip ?? ''))
      ab.append('address[country]', 'US')
      try {
        await fetch(`https://api.stripe.com/v1/customers/${customerId}`, {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${stripeKey}`,
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: ab.toString(),
        })
      } catch (e) {
        // Never block an order on this. Stripe falls back to the billing
        // address, which is what it did before this existed.
        console.error('could not set customer tax address', String(e))
      }
    }

    // ---- Build the Checkout Session ---------------------------------------
    const body = new URLSearchParams()
    body.append('mode', 'payment')
    body.append('success_url', success_url)
    body.append('cancel_url', cancel_url)
    body.append('line_items[0][quantity]', '1')
    body.append('line_items[0][price_data][currency]', 'usd')
    body.append('line_items[0][price_data][unit_amount]', String(amountCents))
    body.append('line_items[0][price_data][product_data][name]', job_description ?? 'SnowServ snow removal')
    // Sales tax (Stripe Tax): tax is added ON TOP of the service price (exclusive),
    // never baked in, so final_price stays the pre-tax amount our payout math uses.
    // The product tax category comes from the account default (set to "General -
    // Services" in the Stripe Tax dashboard). INERT until a tax registration exists
    // for the buyer's state — Stripe computes $0 tax where we aren't registered, so
    // this is safe to ship before the NY Certificate of Authority registration.
    body.append('line_items[0][price_data][tax_behavior]', 'exclusive')
    body.append('automatic_tax[enabled]', 'true')
    // Billing address is no longer FORCED. It was required only because Stripe
    // needed some address to source tax, and it now has the service address (see
    // above). Vince, reading the page as a customer: being asked for an address
    // right after typing the service address reads like the app forgot, or like
    // the two are the same thing. 'auto' lets Stripe ask only when the payment
    // itself needs it — Apple Pay and Link already carry one, so most customers
    // never see the field at all.
    body.append('billing_address_collection', 'auto')
    body.append('payment_intent_data[capture_method]', 'manual') // the HOLD
    body.append('payment_intent_data[description]', job_description ?? 'SnowServ snow removal')
    body.append(
      'custom_text[submit][message]',
      'This places a hold — your card is only charged when a provider starts your job.',
    )
    if (customerId) {
      body.append('customer', customerId)
      // 'never', not 'auto': a billing address typed on the Checkout page must
      // NOT overwrite the service address we just set, or tax goes back to being
      // sourced from the payer instead of the property.
      body.append('customer_update[address]', 'never')
      body.append('payment_intent_data[setup_future_usage]', 'off_session')
      // OFFER the card we already have. Without this the saved-card feature was
      // completely broken: Checkout only presents a stored PaymentMethod whose
      // allow_redisplay is 'always', and every card saved through this flow —
      // including real customers' — came back 'unspecified' (verified against
      // live test-mode data 2026-08-12). The result was a returning customer
      // seeing their Visa •••• 4242 listed, a red "payment method required"
      // next to it, and being made to type the whole card in again while the
      // app told them a card was on file.
      //
      // Listing 'unspecified' alongside 'always' covers cards already saved as
      // well as new ones, so nobody has to re-enter a card once to repair it.
      // NOTE (2026-08-12): a returning customer does NOT get a one-tap saved
      // card here, and no parameter fixes that. Hosted Checkout only PREFILLS
      // the card form from the most recent saved card — Stripe's docs say
      // plainly that saved payment methods "don't appear for return purchases
      // in Checkout". Redisplaying a stored card is a Payment Element (embedded)
      // feature.
      //
      // Tried and reverted, both verified by screenshotting the real page:
      //   saved_payment_method_options[allow_redisplay_filters] — no effect
      //   saved_payment_method_options[payment_method_save]=enabled — no effect,
      //     AND it hands the customer a checkbox that can DECLINE saving the
      //     card. That silently breaks storm bookings, which charge off-session
      //     against users.card_pm_id and simply fail with "No card on file" if
      //     it was never saved. Forcing setup_future_usage above is what
      //     guarantees we always have one.
      //
      // The real options are: live with prefill (current), or migrate to the
      // embedded Payment Element — which would also require registering every
      // domain for Apple Pay, a cost the hosted page avoids entirely.
    }
    for (const [k, v] of Object.entries(meta)) body.append(`metadata[${k}]`, v)

    const response = await fetch('https://api.stripe.com/v1/checkout/sessions', {
      method: 'POST',
      headers: { Authorization: `Bearer ${stripeKey}`, 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body.toString(),
    })
    const session = await response.json()
    if (session.error) return json({ error: session.error.message }, 400)

    // amount_total is the server-computed charge (authoritative) — returned so the
    // app can confirm what will be held, and never a client-supplied figure.
    return json({
      url: session.url,
      session_id: session.id,
      stripe_customer_id: customerId,
      amount_total: session.amount_total,
    })
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    return json({ error: msg }, 500)
  }
})
