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

const perProperty = (zonePrice: unknown, mult: number) =>
  Math.round((Number(zonePrice) || 0) * mult)

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

    // ---- Compute the price (same math the app shows) ----------------------
    const servicePrice = wantsWalkway && wantsDriveway
      ? perProperty(zone.price_both, multiplier)
      : wantsDriveway
        ? perProperty(zone.price_driveway, multiplier)
        : perProperty(zone.price_sidewalk, multiplier)
    // Deicer is priced per surface. price_salting is the both-surfaces price;
    // the per-surface columns coalesce back to it so a zone row written before
    // those columns existed prices sanely instead of charging $0.
    // ⚠️ Must stay in lockstep with _priceSalting in customer_home.dart — this
    // side is what the customer is CHARGED, that side is what they were SHOWN.
    const saltingKey = wantsWalkway && wantsDriveway
      ? 'price_salting'
      : wantsDriveway
        ? 'price_salting_driveway'
        : 'price_salting_sidewalk'
    const saltingPrice = wantsSalting
      ? perProperty(zone[saltingKey] ?? zone.price_salting, multiplier)
      : 0
    const baseTotal = servicePrice + saltingPrice
    const stormBands = await loadStormBands(supabaseUrl, dbHeaders)
    const storm = await surgeForPoint(geo?.lat ?? null, geo?.lng ?? null, stormBands)
    const surge = storm.mult
    const finalPrice = Math.round(baseTotal * surge)
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
    // automatic_tax needs an address to source the rate: collect the payer's billing
    // address on the Checkout page and let Stripe use it (customer_update[address]).
    body.append('billing_address_collection', 'required')
    body.append('payment_intent_data[capture_method]', 'manual') // the HOLD
    body.append('payment_intent_data[description]', job_description ?? 'SnowServ snow removal')
    body.append(
      'custom_text[submit][message]',
      'This places a hold — your card is only charged when a provider starts your job.',
    )
    if (customerId) {
      body.append('customer', customerId)
      body.append('customer_update[address]', 'auto') // save the collected address for tax
      body.append('payment_intent_data[setup_future_usage]', 'off_session')
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
