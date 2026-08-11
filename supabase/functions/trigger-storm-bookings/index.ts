// Fires "book my next storm" standing orders — see the storm_bookings migration.
//
// THE RULE, and it is the whole feature (Vince, 2026-08-07): "book ahead of time
// FOR WHEN THE STORM IS DONE." Two conditions, both required:
//   1. enough NEW snow has fallen  (>= booking.trigger_inches in the last 24h)
//   2. it has STOPPED              (< STOPPED_INCHES forecast over the next
//                                   QUIET_HOURS)
// Firing on accumulation alone would send a provider into hour two of a
// ten-hour storm to clear a driveway that fills back in by morning — and we'd
// have charged for it.
//
// PAYMENT: authorized OFF-SESSION here, at today's prices, never at booking
// time. A Stripe authorization dies after ~7 days and storms don't schedule
// themselves, so holding at booking would guarantee a dead PaymentIntent.
//
// Called by cron every 30 min. verify_jwt=false; guarded by a shared secret so
// only the cron can fire it (it moves money).

const QUIET_HOURS = 3      // hours of near-zero snowfall that mean "it stopped"
const STOPPED_INCHES = 0.2 // total forecast snow over QUIET_HOURS to still count as stopped
const M_TO_IN = 39.3701

const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { 'Content-Type': 'application/json' } })

type Weather = { fellInches: number; comingInches: number }

// Geocoding, same chain as create-checkout-session and lib/utils/geocode.dart:
// US Census primary (free, keyless, permits server use), Nominatim fallback.
// Keep all three in lockstep.
//
// addresses.lat/lng existed but was NULL on every row (verified 2026-08-07) —
// nothing ever populated it. We resolve on demand and CACHE IT BACK, so it's
// about one call per address ever rather than one per booking per half hour.
async function geocode(a: Record<string, unknown>): Promise<{ lat: number; lng: number } | null> {
  const oneLine = [a.address_line, a.city, a.state, a.zip]
    .map((v) => String(v ?? '').trim()).filter(Boolean).join(', ')
  if (!oneLine) return null
  try {
    const r = await fetch(
      'https://geocoding.geo.census.gov/geocoder/locations/onelineaddress' +
      `?address=${encodeURIComponent(oneLine)}&benchmark=Public_AR_Current&format=json`,
    ).then((r) => r.json())
    const m = r?.result?.addressMatches?.[0]?.coordinates
    if (m && Number.isFinite(m.y) && Number.isFinite(m.x)) {
      return { lat: Number(m.y), lng: Number(m.x) }
    }
  } catch { /* fall through */ }
  try {
    const r = await fetch(
      `https://nominatim.openstreetmap.org/search?q=${encodeURIComponent(oneLine)}&format=json&limit=1`,
      { headers: { 'User-Agent': 'SnowServ/1.0 (support@snowserv.app)' } },
    ).then((r) => r.json())
    const hit = Array.isArray(r) ? r[0] : null
    if (hit) return { lat: Number(hit.lat), lng: Number(hit.lon) }
  } catch { /* give up */ }
  return null
}

// Open-Meteo, same source the storm-pricing surge already uses. `snowfall` is
// hourly centimetres of NEW snow, which is what we want — snow_depth would
// include old pack from last week's storm and fire a booking on a clear day.
async function weatherFor(lat: number, lng: number): Promise<Weather | null> {
  try {
    const url =
      `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lng}` +
      `&hourly=snowfall&past_days=1&forecast_days=2&timezone=auto`
    const r = await fetch(url).then((r) => r.json())
    const times: string[] = r?.hourly?.time ?? []
    const snow: number[] = r?.hourly?.snowfall ?? []
    if (!times.length || times.length !== snow.length) return null

    const now = Date.now()
    let fellCm = 0
    let comingCm = 0
    for (let i = 0; i < times.length; i++) {
      // Open-Meteo returns local wall-clock without a zone; treating it as UTC
      // is fine because we only ever compare it to `now` in the same frame.
      const t = new Date(times[i] + 'Z').getTime()
      const hoursOut = (t - now) / 3_600_000
      const cm = Number(snow[i]) || 0
      if (hoursOut <= 0 && hoursOut > -24) fellCm += cm
      if (hoursOut > 0 && hoursOut <= QUIET_HOURS) comingCm += cm
    }
    return { fellInches: (fellCm / 2.54), comingInches: (comingCm / 2.54) }
  } catch {
    return null
  }
}

Deno.serve(async (req: Request) => {
  try {
    // Only the cron may fire this — it authorizes cards.
    const secret = Deno.env.get('CRON_SECRET')
    if (secret) {
      const given = (req.headers.get('Authorization') ?? '').replace('Bearer ', '')
      if (given !== secret && given !== Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')) {
        return json({ error: 'Unauthorized' }, 401)
      }
    }

    const url = Deno.env.get('SUPABASE_URL')!
    const svcKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')!
    const svc = { apikey: svcKey, Authorization: `Bearer ${svcKey}` }
    const jsonSvc = { ...svc, 'Content-Type': 'application/json' }

    const bookings = await (await fetch(
      `${url}/rest/v1/storm_bookings?status=eq.active&select=*,addresses(*),users!storm_bookings_customer_id_fkey(stripe_customer_id,card_pm_id)`,
      { headers: svc })).json()
    // Report a query FAILURE as a failure. The first version returned
    // {checked: 0} for a permission error, which reads exactly like "no
    // bookings" — the cron would have run every 30 minutes for a whole winter
    // firing nothing and looking healthy while doing it.
    if (!Array.isArray(bookings)) {
      console.error('storm_bookings query failed', JSON.stringify(bookings))
      return json({ error: 'Could not read bookings', detail: bookings }, 500)
    }
    if (bookings.length === 0) return json({ checked: 0, fired: 0 })

    const zones = await (await fetch(
      `${url}/rest/v1/service_areas?is_active=eq.true&select=*`, { headers: svc })).json()
    const settings = await (await fetch(
      `${url}/rest/v1/app_settings?select=key,value`, { headers: svc })).json()
    const setting = (k: string) =>
      (Array.isArray(settings) ? settings.find((s: {key:string}) => s.key === k)?.value : null)

    let bands: Array<{ min: number; mult: number }> = [{ min: 0, mult: 1 }]
    try { bands = JSON.parse(setting('storm_bands') ?? '') ?? bands } catch { /* defaults */ }

    // Ceiling on storm pricing for a BOOKED job. This fires while the customer
    // is asleep and charges their card off-session, so they never get to see
    // the multiplier and decline it the way an on-demand customer does. The cap
    // is what stands in for that missing consent, and it is what the booking
    // card promises them. Default 1.5 — on the launch ladder (1.0/1.2/1.5/2.0)
    // that only bites in a 10"+ blizzard, so it costs nothing on ordinary snow.
    // Clamped to a sane range so a bad settings value can't uncap the charge.
    const rawCap = Number(setting('storm_booking_max_surge'))
    const surgeCap = Number.isFinite(rawCap) && rawCap >= 1 && rawCap <= 5
      ? rawCap
      : 1.5

    let fired = 0
    const results: unknown[] = []

    for (const b of bookings) {
      const addr = b.addresses
      const stamp = async (patch: Record<string, unknown>) => {
        await fetch(`${url}/rest/v1/storm_bookings?id=eq.${b.id}`, {
          method: 'PATCH', headers: jsonSvc,
          body: JSON.stringify({ last_checked_at: new Date().toISOString(), ...patch }),
        })
      }

      // Number(null) is 0, NOT NaN — so a null lat/lng sailed through an
      // isFinite() check as the valid coordinate 0, and we'd have asked for the
      // weather at 0°N 0°E in the Gulf of Guinea. It has never snowed there, so
      // every booking would have quietly never fired, all winter, with the
      // function reporting "not enough snow yet" the whole time. Coerce only
      // after establishing the value actually exists.
      const rawLat = addr?.lat, rawLng = addr?.lng
      let lat = rawLat == null ? NaN : Number(rawLat)
      let lng = rawLng == null ? NaN : Number(rawLng)
      if (!Number.isFinite(lat) || !Number.isFinite(lng) || (lat === 0 && lng === 0)) {
        const geo = await geocode(addr ?? {})
        if (!geo) {
          // We cannot know the weather at an address we cannot place. Record it
          // on the row rather than silently never firing — a booking that never
          // fires and never explains itself is worse than no booking.
          await stamp({ last_error: 'Could not locate this address' })
          results.push({ id: b.id, skipped: 'geocode failed' })
          continue
        }
        lat = geo.lat; lng = geo.lng
        // Cache so this is roughly one lookup per address, ever. Logged rather
        // than swallowed: if this quietly fails we re-geocode every address on
        // every tick forever, which is invisible until someone rate-limits us.
        try {
          const cacheRes = await fetch(`${url}/rest/v1/addresses?id=eq.${b.address_id}`, {
            method: 'PATCH', headers: jsonSvc,
            body: JSON.stringify({ lat, lng }),
          })
          if (!cacheRes.ok) {
            console.error('geocode cache write failed',
              cacheRes.status, await cacheRes.text().catch(() => ''))
          }
        } catch (e) {
          console.error('geocode cache write threw', String(e))
        }
      }

      const w = await weatherFor(lat, lng)
      if (!w) { await stamp({ last_error: 'Weather lookup failed' }); continue }

      const enough = w.fellInches >= Number(b.trigger_inches)
      const stopped = w.comingInches < STOPPED_INCHES
      if (!enough || !stopped) {
        await stamp({
          last_error: null,
          // Useful in the admin panel: "2.4in fell, 0.6in still coming" explains
          // exactly why a booking hasn't fired yet.
        })
        results.push({
          id: b.id, fired: false,
          fell: +w.fellInches.toFixed(2), coming: +w.comingInches.toFixed(2),
          reason: !enough ? 'not enough snow yet' : 'still snowing',
        })
        continue
      }

      // ---- price it, at TODAY's zone prices, not the prices when they booked
      const zone = (Array.isArray(zones) ? zones : []).find((z: Record<string, unknown>) =>
        String(z.name ?? '').length > 0) // single active zone today; see matchZone TODO below
      if (!zone) { await stamp({ last_error: 'No active service zone' }); continue }

      const mult = Number(addr?.price_multiplier ?? 1) || 1
      const per = (v: unknown) => Math.round((Number(v) || 0) * mult)
      const servicePrice =
        b.service_type === 'sidewalk_driveway' ? per(zone.price_both)
        : b.service_type === 'driveway' ? per(zone.price_driveway)
        : per(zone.price_sidewalk)
      const saltKey =
        b.service_type === 'sidewalk_driveway' ? 'price_salting'
        : b.service_type === 'driveway' ? 'price_salting_driveway'
        : 'price_salting_sidewalk'
      const saltPrice = b.salting ? per(zone[saltKey] ?? zone.price_salting) : 0

      let surge = 1
      for (const band of bands) if (w.fellInches >= band.min) surge = band.mult
      // The capped multiplier is what we charge AND what we store on the job, so
      // the receipt, the provider's 75% and the customer's card all agree. The
      // provider is never paid on a number the customer wasn't charged.
      if (surge > surgeCap) surge = surgeCap
      const base = servicePrice + saltPrice
      const finalPrice = Math.round(base * surge)
      const cents = finalPrice * 100
      if (!Number.isFinite(cents) || cents < 50) {
        await stamp({ last_error: 'Could not price this booking' }); continue
      }

      // ---- authorize the saved card OFF-SESSION (a hold, same as an order)
      const customer = b.users?.stripe_customer_id
      const pm = b.users?.card_pm_id
      if (!customer || !pm) {
        await stamp({ status: 'failed', last_error: 'No card on file' })
        results.push({ id: b.id, failed: 'no card' })
        continue
      }

      const form = new URLSearchParams()
      form.append('amount', String(cents))
      form.append('currency', 'usd')
      form.append('customer', customer)
      form.append('payment_method', pm)
      form.append('off_session', 'true')
      form.append('confirm', 'true')
      form.append('capture_method', 'manual')
      form.append('description', `SnowServ storm booking ${b.id}`)
      const pi = await (await fetch('https://api.stripe.com/v1/payment_intents', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${stripeKey}`,
          'Content-Type': 'application/x-www-form-urlencoded',
          // Same booking + same storm must never double-charge if this function
          // is retried or two cron ticks overlap.
          'Idempotency-Key': `storm-${b.id}-${new Date().toISOString().slice(0, 10)}`,
        },
        body: form.toString(),
      })).json()

      if (pi.error || !pi.id) {
        // A declined card is a dead end for THIS booking — stop retrying every
        // 30 minutes and tell them, rather than hammering a card that says no.
        await stamp({ status: 'failed', last_error: pi.error?.message ?? 'Card authorization failed' })
        await fetch(`${url}/functions/v1/notify-customer`, {
          method: 'POST', headers: jsonSvc,
          body: JSON.stringify({ user_id: b.customer_id, status: 'storm_booking_failed' }),
        }).catch(() => {})
        results.push({ id: b.id, failed: pi.error?.message })
        continue
      }

      // ---- the customer's standing note for THIS property ------------------
      // A storm booking fires at 4am with nobody awake, so it is the one order
      // the customer cannot be asked about — which makes carrying the gate code
      // MORE important here, not less. Without this the auto-created job went
      // out with an empty note and the provider met a locked gate on exactly
      // the orders the note exists to prevent.
      //
      // Same rule the order screen prefills by (customer_home
      // _prefillNotesForSavedAddress): the most recent note left at this
      // address wins. Read at TRIGGER time, not booking time, so editing the
      // note on any ordinary order also updates what the next storm job says.
      let carriedNotes: string | null = null
      try {
        const nRes = await fetch(
          `${url}/rest/v1/jobs?select=customer_notes` +
          `&customer_id=eq.${b.customer_id}&address_id=eq.${b.address_id}` +
          `&customer_notes=not.is.null&order=created_at.desc&limit=1`,
          { headers: svc })
        if (nRes.ok) {
          const n = (await nRes.json())?.[0]?.customer_notes
          if (typeof n === 'string' && n.trim()) carriedNotes = n.trim()
        } else {
          console.error('note carry-over lookup failed', nRes.status)
        }
      } catch (e) {
        // Never block the job on this — a job without the note still beats no
        // job at all during a storm.
        console.error('note carry-over lookup threw', String(e))
      }

      // ---- create the job, exactly as the webhook would for a normal order
      const jobRow = await (await fetch(`${url}/rest/v1/jobs`, {
        method: 'POST',
        headers: { ...jsonSvc, Prefer: 'return=representation' },
        body: JSON.stringify({
          customer_id: b.customer_id,
          address_id: b.address_id,
          ...(carriedNotes ? { customer_notes: carriedNotes } : {}),
          service_type: b.service_type,
          walkway: b.service_type !== 'driveway',
          driveway: b.service_type !== 'sidewalk',
          salting: b.salting,
          driveway_size: b.driveway_size,
          base_price: base,
          surge_multiplier: surge,
          final_price: finalPrice,
          // What we measured, kept with the job it priced. NOTE this is NEW
          // snow that fell in this storm (hourly `snowfall`), whereas an
          // on-demand order prices on snow currently ON THE GROUND (`current
          // .snow_depth`) — a booking is paid for clearing one storm, an
          // on-demand order for clearing whatever is lying there. The receipt
          // says which, because "you said 12 inches, I measured 11" is only
          // settleable if both sides know what was being measured.
          snow_level: Number(w.fellInches.toFixed(1)),
          status: 'requested',
          payment_intent_id: pi.id,
          job_lat: lat,
          job_lng: lng,
        }),
      })).json()

      const jobId = Array.isArray(jobRow) ? jobRow[0]?.id : null
      await stamp({ status: 'triggered', triggered_at: new Date().toISOString(), job_id: jobId, last_error: null })

      // Hand it to the same dispatcher every other job goes through.
      await fetch(`${url}/rest/v1/rpc/dispatch_jobs`, { method: 'POST', headers: jsonSvc, body: '{}' })
        .catch(() => {})
      await fetch(`${url}/functions/v1/notify-customer`, {
        method: 'POST', headers: jsonSvc,
        body: JSON.stringify({ job_id: jobId, status: 'storm_booking_triggered' }),
      }).catch(() => {})

      fired++
      results.push({ id: b.id, fired: true, job_id: jobId, fell: +w.fellInches.toFixed(2), price: finalPrice })
    }

    return json({ checked: bookings.length, fired, results })
  } catch (e: unknown) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500)
  }
})
