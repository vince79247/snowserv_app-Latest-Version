import { shell } from '../_shared/email_shell.ts'

// Sends provider mail as real HTML, with a real button, to either:
//   { lead_id }     — a provider_leads row (came in via the website form), or
//   { provider_id } — a signup stuck at 'incomplete', or one waiting at
//                     'pending_review' (finished, awaiting our approval)
//
// Why this exists when the admin panel can already open a mailto: draft: a
// mailto body is plain text by specification. It cannot carry a link, a button,
// or any formatting, and it composes from whatever account the admin's mail app
// happens to default to — Vince nearly sent recruiting mail from his personal
// address, and separately had a draft silently not send at all. This path sends
// as SnowServ, server-side, and records that it went.
//
// AUTH MODEL: admin only. Unlike send-welcome-email (fired by a pg trigger via
// pg_net, guarded by idempotency), this mails an arbitrary address on demand, so
// it verifies the CALLER's login token maps to profiles.is_admin — the same check
// admin-doc-url uses. Without that it would be an open relay aimed at our own
// lead list.
//
// PRICES ARE COMPUTED SERVER-SIDE from the live zone row and the live commission
// setting, never passed in by the client and never typed into a template. Stale
// recruiting prices have already cost us once (2026-08-04, ~25% low).

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  })

// ⚠️ NEVER put "noreply" back in this address. It is the FROM line a human
// reads, and it overrides whatever the body asks them to do. Isaiah sat
// approved and unable to work from 2026-08-09 to 2026-10-15; two of the five
// emails he got asked him to "just hit reply" and he never did — he answered
// the moment Vince texted him from a real phone number. reply_to has always
// pointed at support@snowserv.app (verified receiving 2026-10-15: all five
// BCCs present, plus a direct inbound test), so replies were always going to
// land. The sender address was telling people not to try.
const FROM = 'Vince at SnowServ <vince@send.snowserv.app>'
const REPLY_TO = 'support@snowserv.app'
const SIGNUP_URL = 'https://app.snowserv.app'

const p = (t: string) =>
  `<p style="margin:0 0 14px;font-size:15px;line-height:1.55;color:#15242F;">${t}</p>`

// Table-based so Outlook renders it. A styled <a> alone collapses there.
const button = (href: string, label: string) =>
  `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:6px 0 22px;">
     <tr><td align="center" bgcolor="#1565C0" style="border-radius:6px;">
       <a href="${href}" style="display:inline-block;padding:14px 30px;font-size:16px;font-weight:bold;color:#ffffff;text-decoration:none;border-radius:6px;">${label}</a>
     </td></tr>
   </table>`

// Two columns on purpose. A single "$60" next to "you keep 75%" is genuinely
// ambiguous — is the job worth $60, or is $60 my share of it? A contractor
// deciding whether to drive out in a storm cannot be left doing that arithmetic,
// and getting it wrong in the pessimistic direction costs us the recruit.
// Showing what the customer pays alongside what he takes home makes the split
// self-evident and does not need a sentence to explain it.
const payTable = (rows: Array<[string, number, number]>) =>
  `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 8px;width:100%;max-width:420px;">
     <tr>
       <td style="padding:0 12px 6px;font-size:12px;color:#5A7184;">&nbsp;</td>
       <td align="right" style="padding:0 12px 6px;font-size:12px;color:#5A7184;">Customer pays</td>
       <td align="right" style="padding:0 12px 6px;font-size:12px;color:#5A7184;font-weight:bold;">You take home</td>
     </tr>
     ${rows.map(([label, price, cut], i) => `
     <tr>
       <td style="padding:9px 12px;font-size:15px;color:#15242F;background:${i % 2 ? '#FFFFFF' : '#F0F6FF'};border-radius:4px 0 0 4px;">${label}</td>
       <td align="right" style="padding:9px 12px;font-size:15px;color:#5A7184;background:${i % 2 ? '#FFFFFF' : '#F0F6FF'};">$${price}</td>
       <td align="right" style="padding:9px 12px;font-size:16px;font-weight:bold;color:#15242F;background:${i % 2 ? '#FFFFFF' : '#F0F6FF'};border-radius:0 4px 4px 0;">$${cut}</td>
     </tr>`).join('')}
   </table>`

const esc = (s: string) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

const BANK_NOTE =
  '<b>Your bank details go to Stripe, not to us.</b> You set up payouts on ' +
  'Stripe\'s own secure page — SnowServ never sees or stores your bank account ' +
  'or Social Security number. Stripe pays you directly and issues your 1099 at ' +
  'the end of the year.'

// SnowServ is seasonal and most of the calendar year has no snow in it. Telling a
// contractor to "go online and start taking jobs right away" in August reads as
// absurd and burns the credibility we spent the whole recruiting effort earning.
// A single static reword just moves the problem to winter, where "go online" IS
// the correct call to action — so branch on the actual month instead.
// Yonkers snow season: roughly November through March.
type SeasonPhase = 'in' | 'pre' | 'off'

// THREE phases, not two. A boolean in/out of season produced a real failure:
// on 2026-10-15 an approved provider was told "it does not snow in the summer",
// in mid-October, with the first storm weeks away. Vince caught it — "obviously
// we have four seasons in New York".
//   'in'  Nov–Mar  — it is snowing; go online.
//   'pre' Oct      — snow is WEEKS away. The highest-urgency month there is for
//                    getting somebody payout-ready, and the old copy told them
//                    to relax.
//   'off' Apr–Sep  — genuinely nothing to do; set payouts up at leisure.
function seasonPhase(now = new Date()): SeasonPhase {
  // Month resolved in America/New_York so a UTC edge near midnight on the 1st or
  // 31st cannot flip the season by a day.
  const m = Number(new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/New_York',
    month: 'numeric',
  }).format(now))
  if (m >= 11 || m <= 3) return 'in'
  if (m === 10) return 'pre'
  return 'off'
}

// ⚠️ PAYOUTS ARE A GATE, NOT A CONVENIENCE — say so in every phase.
// provider_home.dart blocks the online toggle unless payouts_enabled is true
// ("working a storm for money we cannot send"), so an approved provider without
// it cannot go online and cannot be dispatched anything. The old copy said
// "we can hand you work but not money" (in season) and "so you get paid without
// a delay ... your call" (off season). Both are false and both understate it.
// Isaiah was approved 2026-08-08, received the soft version, and ten weeks later
// was still unable to take a job.
const PAYOUT_GATE =
  '<b>You cannot go online until this is done.</b> It is not paperwork for ' +
  'later — it is the switch that turns your account on. Until payouts are set ' +
  'up we cannot send you a single job.'

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  try {
    const apiKey = Deno.env.get('RESEND_API_KEY')
    if (!apiKey) return json({ error: 'RESEND_API_KEY not configured' }, 503)

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!
    const svc = { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` }

    // --- caller must be an admin, OR the server itself ---------------------
    // The nightly chase-providers cron calls this with the SERVICE ROLE key.
    // That is safe for the same reason the admin path is: there is no `to`
    // parameter anywhere in this function — the recipient is resolved
    // server-side from a lead_id/provider_id that must already exist in our own
    // tables. A stolen key could only re-mail people we already know, with copy
    // it does not control. The service key is server-only and never ships to a
    // client. sent_by stays NULL for these, which is how the admin panel tells a
    // scheduled nudge from one a human chose to send.
    const token = (req.headers.get('Authorization') ?? '').replace('Bearer ', '')
    let userId: string | null = null

    if (token && token === serviceKey) {
      userId = null // automated send
    } else {
      const userRes = await fetch(`${supabaseUrl}/auth/v1/user`, {
        headers: { apikey: anonKey, Authorization: `Bearer ${token}` },
      })
      userId = (await userRes.json())?.id ?? null
      if (!userId) return json({ error: 'Unauthorized' }, 401)

      const profs = await (await fetch(
        `${supabaseUrl}/rest/v1/profiles?id=eq.${userId}&select=is_admin`,
        { headers: svc })).json()
      if (!Array.isArray(profs) || profs[0]?.is_admin !== true) {
        return json({ error: 'Forbidden — admins only' }, 403)
      }
    }

    // --- who are we writing to? --------------------------------------------
    const { lead_id, provider_id, review_note } = await req.json()
    if (!lead_id && !provider_id) {
      return json({ error: 'lead_id or provider_id required' }, 400)
    }

    let to = ''
    let firstName = ''
    let leadStatus: string | null = null
    // Hoisted beside leadStatus so the status write at the bottom can honor
    // "first contact wins" — `lead` itself is block-scoped to the fetch above.
    let leadContactedAt: string | null = null
    let regStatus: string | null = null
    let providerUserId = ''
    let payoutsEnabled = false
    let alreadyWelcomed = false
    // Assume confirmed. Only the provider path can prove otherwise, and a lead
    // has no auth account at all, so "confirmed" is the correct default there.
    let emailConfirmed = true

    if (lead_id) {
      const rows = await (await fetch(
        `${supabaseUrl}/rest/v1/provider_leads?id=eq.${lead_id}&select=id,name,email,status,contacted_at`,
        { headers: svc })).json()
      const lead = Array.isArray(rows) ? rows[0] : null
      if (!lead) return json({ error: 'Lead not found' }, 404)
      to = (lead.email ?? '').toString().trim()
      firstName = (lead.name ?? '').toString().trim().split(/\s+/)[0] ?? ''
      leadStatus = (lead.status ?? 'new').toString()
      leadContactedAt = lead.contacted_at ? String(lead.contacted_at) : null
    } else {
      const rows = await (await fetch(
        `${supabaseUrl}/rest/v1/providers?id=eq.${provider_id}&select=id,user_id,registration_status,payouts_enabled,users!inner(name,email)`,
        { headers: svc })).json()
      const prov = Array.isArray(rows) ? rows[0] : null
      if (!prov) return json({ error: 'Provider not found' }, 404)
      to = (prov.users?.email ?? '').toString().trim()
      firstName = (prov.users?.name ?? '').toString().trim().split(/\s+/)[0] ?? ''
      regStatus = (prov.registration_status ?? '').toString()
      providerUserId = (prov.user_id ?? '').toString()
      payoutsEnabled = prov.payouts_enabled === true

      // "Approved" is TWO different messages depending on whether they have
      // already been welcomed. Deriving that from row state alone is not
      // possible — recruit_emailed_at is stamped by every send, including lead
      // mail — so ask the record that actually knows: has an `approved` email
      // already gone to this provider? If yes, the next message should chase the
      // payout setup, not re-announce an approval they received weeks ago.
      // Isaiah was approved 2026-08-08 and has been stuck ever since; re-sending
      // "you're approved" would read as a mail-merge fault.
      try {
        const prior = await (await fetch(
          `${supabaseUrl}/rest/v1/email_log?provider_id=eq.${provider_id}` +
          `&template=eq.approved&select=id&limit=1`,
          { headers: svc })).json()
        alreadyWelcomed = Array.isArray(prior) && prior.length > 0
      } catch (_) { /* leave false — worst case they get the approval email */ }

      // "Incomplete" hides TWO different people, and until 2026-09-24 we mailed
      // them both the same thing. Three of the five real stalled providers had
      // never confirmed their email and had last_sign_in_at = null — email
      // confirmation is required to log in, so they were locked out of the
      // account they had just created. Every one of them was sent "Finishing
      // your SnowServ provider account", which asks them to go do the one thing
      // they cannot do, and carries no confirmation link. Read the auth record
      // so the variant can tell "locked out" from "genuinely stalled".
      // auth.users is not exposed through PostgREST; the Admin API is the way in.
      if (providerUserId) {
        try {
          const au = await (await fetch(
            `${supabaseUrl}/auth/v1/admin/users/${providerUserId}`,
            { headers: svc })).json()
          // ⚠️ GoTrue OMITS email_confirmed_at from the JSON entirely when the
          // address was never confirmed — it does not send null. So absence of
          // the field IS the unconfirmed signal, and testing `'x' in au` reads
          // every unconfirmed user as confirmed. (That exact mistake shipped
          // here first and was caught only by running it against a real
          // unconfirmed account.) Gate on having got the RIGHT USER back
          // instead: a 404 or an error body has no matching id, so a failed
          // lookup still falls through to the safe default.
          if (au && typeof au === 'object' && au.id === providerUserId) {
            emailConfirmed = !!au.email_confirmed_at
          }
        } catch (_) { /* leave emailConfirmed = true */ }
      }
    }
    if (!to) return json({ error: 'No email address on file' }, 400)

    // A provider row is TWO different conversations, and sending the wrong one
    // is worse than sending nothing: telling somebody who just submitted a
    // complete application to "finish your registration" reads as though we
    // lost it. Branch on the actual status, not on "did the caller pass a
    // provider_id".
    const isPendingReview = !lead_id && regStatus === 'pending_review'
    // Approved, already welcomed, and STILL cannot work: payouts are the gate on
    // going online, so this person is one Stripe page away from being useful and
    // does not know it. This is the single most valuable nudge we send.
    const needsPayouts =
      !lead_id && regStatus === 'approved' && !payoutsEnabled && alreadyWelcomed
    const isApproved = !lead_id && regStatus === 'approved' && !needsPayouts
    const isDeclined = !lead_id && regStatus === 'rejected'
    // A review_note means an admin sent them back to fix something. It arrives
    // in the request because the status write and this send race otherwise —
    // reading it from the row could catch the value before it lands.
    const fixNote = (review_note ?? '').toString().trim()
    const needsFix = !lead_id && fixNote.length > 0
    const isStalledSignupRaw =
      !lead_id && !isPendingReview && !isApproved && !isDeclined && !needsFix
    // Deliberately narrow: only the stalled case splits. Every other status
    // (pending_review, approved, needs-fix) is unreachable without having
    // logged in at least once, so it cannot describe somebody locked out.
    const isUnconfirmed = isStalledSignupRaw && !emailConfirmed
    const isStalledSignup = isStalledSignupRaw && emailConfirmed

    // --- live pay figures --------------------------------------------------
    const zones = await (await fetch(
      `${supabaseUrl}/rest/v1/service_areas?is_active=eq.true&select=price_sidewalk,price_driveway,price_both`,
      { headers: svc })).json()
    const zone = Array.isArray(zones) ? zones[0] : null

    const settings = await (await fetch(
      `${supabaseUrl}/rest/v1/app_settings?key=eq.commission_pct&select=value`,
      { headers: svc })).json()
    const commission = Number(settings?.[0]?.value)
    const providerPct = Number.isFinite(commission) && commission >= 0 && commission <= 100
      ? (100 - commission) / 100
      : 0.75

    const rows: Array<[string, number, number]> = []
    const add = (label: string, raw: unknown) => {
      const v = Number(raw)
      if (Number.isFinite(v) && v > 0) {
        rows.push([label, Math.round(v), Math.round(v * providerPct)])
      }
    }
    if (zone) {
      add('Sidewalk', zone.price_sidewalk)
      add('Driveway', zone.price_driveway)
      add('Sidewalk + driveway', zone.price_both)
    }

    // --- a way back in, for somebody who is locked out ---------------------
    // A magic link rather than a re-sent confirmation email, for two reasons:
    // clicking it CONFIRMS the address and SIGNS THEM IN in one step, and it
    // needs no password — which matters, because these people set a password
    // one to three weeks ago on an account they were never able to use, and
    // "log in with the password you chose" is a second wall behind the first.
    // ⚠️ The link expires after auth's mailer_otp_exp (currently 3600s = ONE
    // HOUR). That is short for cold recruiting mail, so the copy states it
    // plainly and offers a reply — better than a silent dead end. Do NOT raise
    // the global expiry to paper over this; it also governs password resets.
    // Re-sending is one click in the admin panel, which is the intended fix.
    let magicLink = ''
    if (isUnconfirmed) {
      try {
        const lr = await fetch(`${supabaseUrl}/auth/v1/admin/generate_link`, {
          method: 'POST',
          headers: { ...svc, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            type: 'magiclink',
            email: to,
            options: { redirect_to: SIGNUP_URL },
          }),
        })
        const lj = await lr.json()
        // GoTrue has moved this between the top level and .properties across
        // versions; accept either rather than depending on which one we are on.
        magicLink = (lj?.action_link ?? lj?.properties?.action_link ?? '').toString()
      } catch (_) { /* handled below */ }
      // Without the link this email has no purpose — it would be a message
      // telling a locked-out person that they are locked out. Fail loudly so
      // the admin sees it and nothing is written to email_log.
      if (!magicLink) {
        return json({ error: 'Could not generate a sign-in link for this provider' }, 502)
      }
    }

    // --- the message -------------------------------------------------------
    const first = esc(firstName)
    const pct = Math.round(providerPct * 100)

    // A lead parked as out-of-area lives somewhere we have not priced. The pay
    // table is built from the ACTIVE zone (Yonkers), so sending it to him would
    // quote rates for a town he does not work — a promise we might not honour
    // once his area is priced. Percentage is safe anywhere; commission is one
    // global setting. Dollars are not.
    const outOfArea = leadStatus === 'out_of_area'

    const heading = needsFix
      ? (first ? `Hi ${first} — one thing to fix` : 'One thing to fix')
      : isDeclined
      ? (first ? `Hi ${first}` : 'About your application')
      : needsPayouts
      ? (first ? `${first}, you're one step from working` : "One step from working")
      : isApproved
      ? (first ? `You're approved, ${first}` : "You're approved")
      : isPendingReview
      ? (first ? `Hi ${first} — we have your application` : 'We have your application')
      : isUnconfirmed
        ? (first ? `Hi ${first} — let's get you in` : 'Let\'s get you in')
      : isStalledSignup
        ? (first ? `Hi ${first} — you're almost done` : 'You\'re almost done')
        : outOfArea
          ? (first ? `Hi ${first} — not your area yet` : 'Not your area yet')
          : (first ? `Hi ${first} — let's get you working` : 'Let\'s get you working')

    const opening = isStalledSignup
      ? p('You created a SnowServ provider account but did not get to finish ' +
          'setting it up. If something got in the way — anything confusing or ' +
          'broken — just reply and tell me; I would genuinely like to know.') +
        // The confirmation page used to dead-end on a plain page telling people
        // to "head back to the app and log in", with no link. Saying plainly
        // that they are already confirmed removes the exact step that lost them.
        p('<b>You do not need to sign up again.</b> Your email is already ' +
          'confirmed — just log in with the email address and password you ' +
          'chose, and it picks up where you left off.') +
        p('There is not much left. You add your equipment, sign the agreement, ' +
          'and connect a bank account for payouts. About five minutes.')
      : p('Thanks for signing up to clear snow with SnowServ. We\'re a snow removal app ' +
          'launching in Yonkers this winter — customers order a driveway or ' +
          'sidewalk from their phone, and the job goes to the nearest available ' +
          'provider.')

    // Already applied and waiting on us. No pay table and no recruiting pitch —
    // they have seen the rates; what they want to know is that a human has it
    // and what happens next. The one useful action left is payouts, which is
    // the step that most often holds up a first payment.
    // The one email in this file that goes to somebody who is DONE signing up.
    // No recruiting pitch and no re-selling — they already said yes. It answers
    // the only question they now have: what do I do to get a job? Payouts are
    // named because an approved driver with no bank connected earns money the
    // batch cannot pay out.
    // Not a rejection, and worded so it cannot be mistaken for one. Their work
    // is still there, the fix is named, and the button takes them straight back
    // in. This is the message that replaces "contact support for more
    // information", which only ever generated a reply we then had to answer.
    const html = needsFix
      ? shell(heading, [
          p('Thanks for applying to clear snow with SnowServ. Your application is ' +
            'nearly there — there is one thing we need you to sort out:'),
          `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 18px;width:100%;">
             <tr><td style="padding:14px 16px;background:#FFF8E1;border-left:4px solid #F5A623;border-radius:4px;font-size:15px;line-height:1.55;color:#15242F;">${esc(fixNote)}</td></tr>
           </table>`,
          p('<b>Nothing you have already filled in is lost.</b> Log in, fix ' +
            'that one item, and submit again — it takes a minute.'),
          button(SIGNUP_URL, 'Log in and fix it'),
          p('If something about this does not look right, just reply and tell ' +
            'me — a real person reads it.'),
        ].join(''))
      // A genuine decline. Deliberately short and final: no specific reason,
      // because a stated reason on a judgment call invites a negotiation we
      // will not have, and nothing vague enough to be safe is honest enough to
      // be useful. It does NOT say "contact support for more information" — the
      // old screen did, and that sentence exists only to generate email.
      : isDeclined
      ? shell(heading, [
          p('Thanks for taking the time to apply to SnowServ.'),
          p('We are not able to approve your application to work as a provider, ' +
            'and this decision is final.'),
          p('I appreciate your interest, and I am sorry not to have better news.'),
          p('Vince<br>SnowServ'),
        ].join(''))
      // Approved weeks ago, welcomed, and still blocked. Deliberately SHORT and
      // does not re-sell the job — they already said yes. It names the one thing
      // and why it matters, and gives a graceful exit, because an honest "no"
      // from somebody who has gone quiet is worth more at this point than
      // silence: it tells Vince whether to count them as supply.
      : needsPayouts
      ? shell(heading, [
          p('You were approved to clear snow with SnowServ, but your account ' +
            'still cannot be sent any work — payouts were never set up.'),
          p(PAYOUT_GATE),
          p('It takes about five minutes on Stripe\'s page.'),
          p(BANK_NOTE),
          button(SIGNUP_URL, 'Set up your payouts'),
          rows.length ? payTable(rows) : '',
          rows.length
            ? p('<span style="font-size:13px;color:#5A7184;">The right-hand ' +
                'column is your money. Deicer pays extra on top.</span>')
            : '',
          p(seasonPhase() === 'in'
            ? 'It is snowing now, so every day this sits is work going to ' +
              'somebody else.'
            : seasonPhase() === 'pre'
              ? 'The season is close. Finish this week and you are ready for the ' +
                'first storm.'
              : 'There is no rush on the work itself — but get this done and you ' +
                'never have to think about it again.'),
          p('And if you have changed your mind, just reply and say so — I will ' +
            'stop emailing you, no hard feelings at all.'),
        ].join(''))
      : isApproved
      ? shell(heading, ((): string[] => {
          // Shared tail: the pay table, the gate, the button. Only the opening
          // and the closing line change by season, so they do not drift apart.
          const payBits = [
            rows.length ? payTable(rows) : '',
            rows.length
              ? p('<span style="font-size:13px;color:#5A7184;">The right-hand ' +
                  'column is your money. Deicer pays extra on top.</span>')
              : '',
            p(PAYOUT_GATE),
            p(BANK_NOTE),
            button(SIGNUP_URL, 'Set up your payouts'),
          ]
          const signOff =
            p('Welcome aboard. Reply to this email any time — a real person reads it.')

          if (seasonPhase() === 'in') {
            return [
              p('Your SnowServ application has been approved — you are cleared to ' +
                'take jobs.'),
              p('<b>One step left: add your bank information.</b> It takes about ' +
                'five minutes on Stripe\'s page.'),
              ...payBits,
              p('Once that is done, open the app and flip yourself <b>Online</b>. ' +
                'You only get job offers while you are online.'),
              signOff,
            ]
          }

          if (seasonPhase() === 'pre') {
            // October. Snow is weeks away, which makes this the single most
            // useful month to get somebody payout-ready — the old copy spent it
            // telling them there was no rush.
            return [
              p('Your SnowServ application has been approved — you are on the ' +
                'roster for this winter.'),
              p('<b>The season is close, so do this now rather than later:</b> ' +
                'set up your bank information. It takes about five minutes on ' +
                'Stripe\'s page, and it is the only thing standing between you ' +
                'and your first job.'),
              ...payBits,
              p('Get it done this week and you are ready the moment the first ' +
                'storm lands — instead of sorting it out at 5am with jobs going ' +
                'to somebody else.'),
              signOff,
            ]
          }

          return [
            p('Your SnowServ application has been approved — you are on the ' +
              'roster for this winter.'),
            p('The season has not started yet, so there are no jobs to take ' +
              'today. But there is one thing worth doing while it is quiet: ' +
              '<b>set up your bank information.</b> About five minutes on ' +
              'Stripe\'s page.'),
            ...payBits,
            p('Do it now and you are done forever — we will email you and send a ' +
              'notification when the first storm is on the way, and you can go ' +
              'straight online.'),
            signOff,
          ]
        })().join(''))
      // Locked out, not disinterested. They signed up and never got in, because
      // the account needs its email confirmed before it will accept a login and
      // that step did not happen. Own it in the first line — this reads as our
      // problem because it is one — then hand them a single button that both
      // confirms the address and signs them in, with no password in the way.
      : isUnconfirmed
      ? shell(heading, [
          p('You signed up to clear snow with SnowServ, but your account was ' +
            'never finished activating — so if you tried to log in, it would ' +
            'not have let you. That is our end, not yours, and I am sorry you ' +
            'were left sitting outside it.'),
          p('<b>The button below fixes it in one tap.</b> It activates your ' +
            'account and signs you straight in — you do not need to remember a ' +
            'password.'),
          button(magicLink, 'Activate my account'),
          p('<span style="font-size:13px;color:#5A7184;">That link is good for ' +
            'two hours. If it has already expired by the time you get to it, ' +
            'just reply to this email and I will send you a fresh one — it ' +
            'takes me a second. And if you are wondering where our first email ' +
            'went, check your spam or junk folder; that is usually where it ' +
            'is.</span>'),
          rows.length
            ? p(`<b>You keep ${pct}% of every job.</b> Here is what that works ` +
                'out to per job in Yonkers:')
            : p(`<b>You keep ${pct}% of every job.</b>`),
          rows.length ? payTable(rows) : '',
          rows.length
            ? p('<span style="font-size:13px;color:#5A7184;">The right-hand ' +
                'column is your money — that is what lands in your bank, not a ' +
                'figure you take a cut out of. Deicer pays extra on top.</span>')
            : '',
          p('Once you are in there is about five minutes left: your equipment, ' +
            'the agreement, and a bank account for payouts.'),
          p(BANK_NOTE),
          p(seasonPhase() === 'in'
            ? 'Finish those and you can go online and start taking jobs.'
            : seasonPhase() === 'pre'
              ? 'The season is close, so it is worth finishing this week — then ' +
                'you are ready the moment the first storm lands.'
              : 'The season has not started yet, so there is no rush — but get ' +
                'it done and you are set. We will email you before the first ' +
                'storm, and that is when the work starts.'),
          p('Just reply to this email if anything looks off — a real person ' +
            'reads it.'),
        ].join(''))
      : isPendingReview
      ? shell(heading, [
          p('Thanks for finishing your SnowServ registration. We have it, and ' +
            'we are reviewing it now.'),
          p('You will hear from us as soon as you are approved, and we will let ' +
            'you know when the season starts and jobs begin coming in.'),
          p('<b>One thing worth doing while you wait:</b> connect your bank ' +
            'account for payouts, so nothing holds up your first payment.'),
          p(BANK_NOTE),
          button(SIGNUP_URL, 'Set up your payouts'),
          p('Just reply to this email if you have any questions — a real person ' +
            'reads it.'),
        ].join(''))
      : outOfArea
      ? shell(heading, [
          p('Thanks for your interest in working with SnowServ. Straight answer: ' +
            'we are not in your area yet. We are launching in Yonkers this winter ' +
            'and expanding town by town, based on where contractors and customers ' +
            'actually are.'),
          p('I have put you on the contractor list for your area. When we get ' +
            'there you get the first call, before the ad goes out.'),
          p(`<b>You would keep ${pct}% of every job</b> — no sign-up fees, no ` +
            'monthly fees, no contract, and you pick which jobs you take. I will ' +
            'have exact rates for your area once we price it.'),
          p(BANK_NOTE),
          p('Just reply to this email with the towns you would cover and what you ' +
            'run — truck and plow, snowblower, or shovel — and I will make sure ' +
            'you are first on the list.'),
        ].join(''))
      : shell(heading, [
          opening,
          p(`<b>You keep ${pct}% of every job.</b> Here is what that works out to ` +
            'per job in Yonkers:'),
          rows.length ? payTable(rows) : '',
          rows.length
            ? p('<span style="font-size:13px;color:#5A7184;">The right-hand ' +
                'column is your money — that is what lands in your bank, not a ' +
                'figure you take a cut out of.</span>')
            : '',
          p('Deicer pays extra on top of those. You choose which jobs you take and ' +
            'you keep your own schedule.'),
          p('No sign-up fees, no monthly fees, no contract.'),
          p(BANK_NOTE),
          button(SIGNUP_URL, isStalledSignup ? 'Finish your registration' : 'Create your account'),
          p('Just reply to this email if you have any questions — a real person reads it.'),
        ].join(''))

    const template = needsFix
      ? 'needs_attention'
      : isDeclined
      ? 'declined'
      : needsPayouts
      ? 'payout_reminder'
      : isApproved
      ? 'approved'
      : isPendingReview
        ? 'pending_review'
        : isUnconfirmed
          ? 'unconfirmed_email'
        : isStalledSignup
          ? 'stalled_signup'
          : outOfArea
            ? 'out_of_area'
            : 'lead_new'

    const subject = needsFix
      ? 'One thing to fix on your SnowServ application'
      : isDeclined
      ? 'About your SnowServ application'
      : needsPayouts
      ? 'One step left before you can take SnowServ jobs'
      : isApproved
      ? "You're approved to work with SnowServ"
      : isPendingReview
        ? 'We have your SnowServ application'
        : isUnconfirmed
          ? 'Your SnowServ account is one tap from being active'
        : isStalledSignup
          ? 'Finishing your SnowServ provider account'
          : outOfArea
            ? 'SnowServ — not your area yet, but you are on the list'
            : 'Clearing snow with SnowServ this winter'

    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: FROM,
        to: [to],
        reply_to: REPLY_TO,
        // Copy the support mailbox on every send. This goes out through Resend,
        // not through the admin's mail client, so without this there is no
        // record anywhere Vince can read — he went looking in Zoho's Sent folder
        // for a message Zoho never touched, and reasonably concluded it failed.
        bcc: [REPLY_TO],
        subject,
        html,
      }),
    })
    if (!res.ok) {
      const detail = await res.text().catch(() => '')
      console.error('Resend send failed', res.status, detail)
      return json({ error: 'Send failed', status: res.status }, 502)
    }

    // Shared history across every sender — see the email_log migration. Written
    // after Resend confirms and best-effort, for the same reason as the status
    // stamps below: the mail is already gone, and failing here must not make a
    // delivered message look undelivered.
    try {
      await fetch(`${supabaseUrl}/rest/v1/email_log`, {
        method: 'POST',
        headers: { ...svc, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          to_email: to,
          subject,
          // The magic link is a working credential — anyone reading it is signed
          // in as that provider. email_log is admin-only and the link dies in an
          // hour, but the log exists so Vince can re-read what he promised
          // somebody, and a sign-in token is no part of that. Strip it.
          body: magicLink ? html.split(magicLink).join('[sign-in link removed]') : html,
          lead_id: lead_id ?? null,
          provider_id: provider_id ?? null,
          template,
          sent_by: userId,
        }),
      })
    } catch (_) { /* the mail is already sent; nothing to undo */ }

    // Record the send only after Resend confirms, so a failure never leaves
    // someone looking like they've been contacted when nothing went out.
    if (!lead_id) {
      // Stamped for BOTH provider variants: it is "when did we last write to
      // this person", and the admin card reads it back so a send is never
      // invisible. Going looking in a Sent folder for mail that never touched
      // it is exactly how this got confusing the first time.
      await fetch(`${supabaseUrl}/rest/v1/providers?id=eq.${provider_id}`, {
        method: 'PATCH',
        headers: { ...svc, 'Content-Type': 'application/json' },
        body: JSON.stringify({ recruit_emailed_at: new Date().toISOString() }),
      })
    } else if (leadStatus === 'new') {
      // ⚠️ contacted_at MUST be stamped here too (fixed 2026-10-15). The admin
      // panel's _setLeadStatus() stamps it when a HUMAN moves the dropdown, but
      // this server path wrote `status` alone — so a lead emailed by the nightly
      // chaser went to 'contacted' with contacted_at still NULL. Six of nine
      // rows were in that state. The card falls back to contacted_at when
      // email_log has nothing for the lead, so the inconsistency was one missing
      // email_log row away from a contacted lead reading as never-contacted.
      // Same rule as the admin path: FIRST contact wins, never overwritten,
      // or the date drifts to whenever we last happened to mail them.
      await fetch(`${supabaseUrl}/rest/v1/provider_leads?id=eq.${lead_id}`, {
        method: 'PATCH',
        headers: { ...svc, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          status: 'contacted',
          ...(leadContactedAt ? {} : { contacted_at: new Date().toISOString() }),
        }),
      })
    }

    return json({ sent: 1, to })
  } catch (e: unknown) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500)
  }
})
