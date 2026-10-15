// chase-providers — the nightly lifecycle chaser.
//
// WHY THIS EXISTS. Every provider who went quiet did so in a way a query could
// have caught, and nobody was running the query:
//   • Isaiah   approved 2026-08-08, payouts never set up. TEN WEEKS idle. He is
//              one Stripe page from being useful and nothing ever told him.
//   • Taj / James / Andy  signed up and never confirmed their email, so they
//              were locked OUT of the account they had just made. Found by hand
//              on 2026-09-24, weeks late.
//   • scott / rosa  got exactly ONE email each, in September, and nothing since.
// Each was found by a person happening to look. This is that look, nightly.
//
// IT DECIDES NOTHING. send-lead-email already picks the right variant from the
// row's own state — unconfirmed_email, stalled_signup, payout_reminder. This
// function only answers "who is overdue a nudge", then calls it. Keeping the
// copy decision in one place is why there is no second set of templates to
// drift.
//
// AUTH: verify_jwt=false (pg_cron cannot hold a user session), so it requires
// the service-role key in the Authorization header and FAILS CLOSED if the
// header is missing or wrong. That is the lesson from the storm-booking cron,
// which 401'd silently for months while reporting success — see
// reference-pg-cron-silent-401.

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })

// Vince's rule, stated 2026-08: "we can pester them once a month."
const QUIET_DAYS = 30
// Stop after this many lifetime contacts. A fifth unanswered email is not
// persistence, it is spam, and it costs sender reputation on the same domain
// that carries confirmation links and payout notices.
const MAX_CONTACTS = 4
// Never chase anyone whose account is older than this with no progress at all.
const STALE_AFTER_DAYS = 120

Deno.serve(async (req: Request) => {
  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

    // Fail closed. A missing or wrong key must 401, never silently no-op.
    const token = (req.headers.get('Authorization') ?? '').replace('Bearer ', '')
    if (!token || token !== serviceKey) {
      return json({ error: 'Unauthorized' }, 401)
    }

    const svc = {
      apikey: serviceKey,
      Authorization: `Bearer ${serviceKey}`,
      'Content-Type': 'application/json',
    }
    const dryRun = new URL(req.url).searchParams.get('dry') === '1'

    // The candidate query lives in SQL (providers_needing_nudge) because it
    // joins auth.users, which PostgREST cannot reach. It reports state only;
    // the thresholds below are this function's decision.
    const rows = await (await fetch(
      `${supabaseUrl}/rest/v1/rpc/providers_needing_nudge`,
      { method: 'POST', headers: svc, body: '{}' },
    ).catch(() => new Response('[]'))).json().catch(() => [])

    const candidates: Array<Record<string, unknown>> = Array.isArray(rows) ? rows : []
    const now = Date.now()
    const days = (iso: unknown) =>
      iso ? (now - new Date(String(iso)).getTime()) / 86_400_000 : Infinity

    const sent: string[] = []
    const skipped: Array<{ who: string; why: string }> = []

    for (const r of candidates) {
      const who = String(r.name ?? r.email ?? r.provider_id)
      if (Number(r.contacts) >= MAX_CONTACTS) {
        skipped.push({ who, why: `${r.contacts} contacts already` }); continue
      }
      if (days(r.recruit_emailed_at) < QUIET_DAYS) {
        skipped.push({ who, why: 'contacted within 30 days' }); continue
      }
      if (days(r.created_at) > STALE_AFTER_DAYS) {
        skipped.push({ who, why: 'account older than 120 days, no progress' }); continue
      }
      if (dryRun) { sent.push(`${who} (dry run)`); continue }

      try {
        const res = await fetch(`${supabaseUrl}/functions/v1/send-lead-email`, {
          method: 'POST', headers: svc,
          body: JSON.stringify({ provider_id: r.provider_id }),
        })
        const body = await res.json().catch(() => ({}))
        if (res.ok && body?.sent === 1) sent.push(who)
        else skipped.push({ who, why: `send failed: ${res.status}` })
      } catch (e) {
        skipped.push({ who, why: `send threw: ${e instanceof Error ? e.message : e}` })
      }
    }

    // Logged so a silent failure is visible in the edge logs, not inferred.
    console.log(JSON.stringify({ dryRun, considered: candidates.length, sent, skipped }))
    return json({ dryRun, considered: candidates.length, sent, skipped })
  } catch (e: unknown) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500)
  }
})
