// storm-alert — tells providers WHEN to be online.
//
// Vince, 2026-10-15: "the providers need to have some sense of when to be
// available for work... Frank should know to toggle online."
//
// A provider only receives job offers while they are ONLINE. Demand is
// concentrated in roughly 48–72 hours around a storm and is near zero the rest
// of the time. Nothing told them which hours mattered: Frank has been online
// since September with zero jobs, and the one night it counts he has no reason
// to expect. This closes that.
//
// ONLY NOTIFIES PEOPLE WHO CAN ACTUALLY WORK — approved AND payouts_enabled.
// Going online is hard-blocked without payouts, so telling a blocked provider
// to go online is noise about something they cannot do. The nightly chaser
// handles those people separately, with the message that actually applies.
//
// AUTH: verify_jwt=false (pg_cron holds no session), requires the service-role
// key, FAILS CLOSED without it.

const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { 'Content-Type': 'application/json' } })

const CM_TO_IN = 1 / 2.54

type Forecast = { stormDate: string; inches: number; startsInHours: number } | null

// Open-Meteo `snowfall` is hourly centimetres of NEW snow — the same field the
// storm-pricing surge uses. NOT snow_depth, which includes last week's pack and
// would fire an alert on a clear day.
async function forecastFor(lat: number, lng: number, lookaheadHours: number, minInches: number): Promise<Forecast> {
  try {
    const url =
      `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lng}` +
      `&hourly=snowfall&forecast_days=4&timezone=auto`
    const r = await fetch(url).then((x) => x.json())
    const times: string[] = r?.hourly?.time ?? []
    const snow: number[] = r?.hourly?.snowfall ?? []
    if (!times.length || times.length !== snow.length) return null

    const now = Date.now()
    // Sum new snow per local calendar day inside the window. Grouping by day is
    // what makes a stable dedupe key: a forecast that shifts by a few hours
    // still lands on the same date, so the same storm is not re-announced every
    // time the model updates.
    const byDay = new Map<string, number>()
    const firstHourOfDay = new Map<string, number>()
    for (let i = 0; i < times.length; i++) {
      const t = new Date(times[i] + 'Z').getTime()
      const hoursOut = (t - now) / 3_600_000
      if (hoursOut <= 0 || hoursOut > lookaheadHours) continue
      const day = times[i].slice(0, 10)
      const inches = (Number(snow[i]) || 0) * CM_TO_IN
      byDay.set(day, (byDay.get(day) ?? 0) + inches)
      if (inches > 0.01 && !firstHourOfDay.has(day)) firstHourOfDay.set(day, hoursOut)
    }
    let best: Forecast = null
    for (const [day, inches] of byDay) {
      if (inches < minInches) continue
      if (!best || inches > best.inches) {
        best = { stormDate: day, inches, startsInHours: firstHourOfDay.get(day) ?? 0 }
      }
    }
    return best
  } catch {
    return null
  }
}

// Zones are polygons, not points. The average of the vertices is plenty for a
// weather lookup — we need the town's forecast, not a specific driveway's.
function centroid(polygon: unknown): { lat: number; lng: number } | null {
  if (!Array.isArray(polygon) || polygon.length === 0) return null
  let la = 0, ln = 0, n = 0
  for (const p of polygon as Array<Record<string, unknown>>) {
    const lat = Number(p?.lat), lng = Number(p?.lng)
    if (Number.isFinite(lat) && Number.isFinite(lng)) { la += lat; ln += lng; n++ }
  }
  return n ? { lat: la / n, lng: ln / n } : null
}

Deno.serve(async (req: Request) => {
  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

    const given = (req.headers.get('Authorization') ?? '').replace('Bearer ', '').trim()
    if (!given || given !== serviceKey) return json({ error: 'Unauthorized' }, 401)

    const svc = { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, 'Content-Type': 'application/json' }
    const url = new URL(req.url)
    const dryRun = url.searchParams.get('dry') === '1'
    // Lets us prove the whole chain out of season without inventing weather.
    const forceInches = Number(url.searchParams.get('force_inches') ?? '')

    const settings = await (await fetch(
      `${supabaseUrl}/rest/v1/app_settings?key=in.(storm_alert_min_inches,storm_alert_lookahead_hours,commission_pct)&select=key,value`,
      { headers: svc })).json()
    const setting = (k: string, d: number) => {
      const v = Number((settings ?? []).find((s: Record<string, unknown>) => s.key === k)?.value)
      return Number.isFinite(v) ? v : d
    }
    const minInches = setting('storm_alert_min_inches', 2)
    const lookahead = setting('storm_alert_lookahead_hours', 72)
    const providerPct = (100 - setting('commission_pct', 25)) / 100

    const zones = await (await fetch(
      `${supabaseUrl}/rest/v1/service_areas?is_active=eq.true&select=id,name,polygon,price_driveway`,
      { headers: svc })).json()

    const out: Array<Record<string, unknown>> = []

    for (const z of (Array.isArray(zones) ? zones : [])) {
      const c = centroid(z.polygon)
      if (!c) { out.push({ zone: z.name, skipped: 'no polygon' }); continue }

      const f = Number.isFinite(forceInches) && forceInches > 0
        ? { stormDate: new Date(Date.now() + 36 * 3_600_000).toISOString().slice(0, 10), inches: forceInches, startsInHours: 36 }
        : await forecastFor(c.lat, c.lng, lookahead, minInches)

      if (!f) { out.push({ zone: z.name, snow: 'none forecast in window' }); continue }

      // Already announced this storm for this zone? The forecast refines every
      // few hours; the provider should hear about it once.
      const dupe = await (await fetch(
        `${supabaseUrl}/rest/v1/storm_alerts?zone_id=eq.${z.id}&storm_date=eq.${f.stormDate}&select=id&limit=1`,
        { headers: svc })).json()
      if (Array.isArray(dupe) && dupe.length && !dryRun) {
        out.push({ zone: z.name, stormDate: f.stormDate, skipped: 'already alerted' }); continue
      }

      // Only people who can actually take a job.
      const provs = await (await fetch(
        `${supabaseUrl}/rest/v1/providers?registration_status=eq.approved&payouts_enabled=eq.true` +
        `&select=id,is_online,users!inner(name,is_test)`,
        { headers: svc })).json()
      const eligible = (Array.isArray(provs) ? provs : [])
        .filter((p: Record<string, unknown>) => (p.users as Record<string, unknown>)?.is_test !== true)

      const when = f.startsInHours < 18 ? 'tonight'
        : f.startsInHours < 42 ? 'tomorrow'
        : new Date(f.stormDate + 'T12:00:00Z').toLocaleDateString('en-US', { weekday: 'long', timeZone: 'UTC' })
      const low = Math.max(1, Math.round(f.inches - 1))
      const high = Math.round(f.inches + 1)
      const pay = Math.round(Number(z.price_driveway ?? 0) * providerPct)

      const title = `Snow ${when} — ${low}–${high}" forecast`
      const body = pay > 0
        ? `Go online ${when} to get job offers in ${z.name}. A driveway pays you $${pay}, more at that depth.`
        : `Go online ${when} to get job offers in ${z.name}.`

      let notified = 0
      if (!dryRun) {
        for (const p of eligible) {
          try {
            const r = await fetch(`${supabaseUrl}/functions/v1/notify-provider`, {
              method: 'POST', headers: svc,
              body: JSON.stringify({ provider_id: p.id, status: 'storm_alert', title, body }),
            })
            if (r.ok) notified++
          } catch { /* one failed push must not stop the rest */ }
        }
        await fetch(`${supabaseUrl}/rest/v1/storm_alerts`, {
          method: 'POST', headers: { ...svc, Prefer: 'return=minimal' },
          body: JSON.stringify({
            zone_id: z.id, storm_date: f.stormDate,
            forecast_inches: Number(f.inches.toFixed(2)), providers_notified: notified,
          }),
        })
      }

      out.push({
        zone: z.name, stormDate: f.stormDate, inches: Number(f.inches.toFixed(2)),
        startsInHours: Math.round(f.startsInHours),
        eligibleProviders: eligible.length,
        alreadyOnline: eligible.filter((p: Record<string, unknown>) => p.is_online === true).length,
        notified: dryRun ? '(dry run)' : notified,
        title, body,
      })
    }

    console.log(JSON.stringify({ dryRun, result: out }))
    return json({ dryRun, result: out })
  } catch (e: unknown) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500)
  }
})
