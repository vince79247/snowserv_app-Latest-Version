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

const FROM = 'SnowServ <noreply@send.snowserv.app>'
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
function inSnowSeason(now = new Date()): boolean {
  // Month resolved in America/New_York so a UTC edge near midnight on the 1st or
  // 31st cannot flip the season by a day.
  const m = Number(new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/New_York',
    month: 'numeric',
  }).format(now))
  return m >= 11 || m <= 3
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  try {
    const apiKey = Deno.env.get('RESEND_API_KEY')
    if (!apiKey) return json({ error: 'RESEND_API_KEY not configured' }, 503)

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!
    const svc = { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` }

    // --- caller must be an admin -------------------------------------------
    const token = (req.headers.get('Authorization') ?? '').replace('Bearer ', '')
    const userRes = await fetch(`${supabaseUrl}/auth/v1/user`, {
      headers: { apikey: anonKey, Authorization: `Bearer ${token}` },
    })
    const userId = (await userRes.json())?.id
    if (!userId) return json({ error: 'Unauthorized' }, 401)

    const profs = await (await fetch(
      `${supabaseUrl}/rest/v1/profiles?id=eq.${userId}&select=is_admin`,
      { headers: svc })).json()
    if (!Array.isArray(profs) || profs[0]?.is_admin !== true) {
      return json({ error: 'Forbidden — admins only' }, 403)
    }

    // --- who are we writing to? --------------------------------------------
    const { lead_id, provider_id, review_note } = await req.json()
    if (!lead_id && !provider_id) {
      return json({ error: 'lead_id or provider_id required' }, 400)
    }

    let to = ''
    let firstName = ''
    let leadStatus: string | null = null
    let regStatus: string | null = null
    let providerUserId = ''
    // Assume confirmed. Only the provider path can prove otherwise, and a lead
    // has no auth account at all, so "confirmed" is the correct default there.
    let emailConfirmed = true

    if (lead_id) {
      const rows = await (await fetch(
        `${supabaseUrl}/rest/v1/provider_leads?id=eq.${lead_id}&select=id,name,email,status`,
        { headers: svc })).json()
      const lead = Array.isArray(rows) ? rows[0] : null
      if (!lead) return json({ error: 'Lead not found' }, 404)
      to = (lead.email ?? '').toString().trim()
      firstName = (lead.name ?? '').toString().trim().split(/\s+/)[0] ?? ''
      leadStatus = (lead.status ?? 'new').toString()
    } else {
      const rows = await (await fetch(
        `${supabaseUrl}/rest/v1/providers?id=eq.${provider_id}&select=id,user_id,registration_status,users!inner(name,email)`,
        { headers: svc })).json()
      const prov = Array.isArray(rows) ? rows[0] : null
      if (!prov) return json({ error: 'Provider not found' }, 404)
      to = (prov.users?.email ?? '').toString().trim()
      firstName = (prov.users?.name ?? '').toString().trim().split(/\s+/)[0] ?? ''
      regStatus = (prov.registration_status ?? '').toString()
      providerUserId = (prov.user_id ?? '').toString()

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
    const isApproved = !lead_id && regStatus === 'approved'
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
      : isApproved
      ? shell(heading, (inSnowSeason()
        ? [
          p('Your SnowServ application has been approved — you are cleared to ' +
            'take jobs.'),
          p('<b>The last thing to do is add your bank information</b>, so we can ' +
            'actually pay you. It takes about five minutes on Stripe\'s page. ' +
            'Until it is done we can hand you work but not money.'),
          p('After that, open the app and flip yourself <b>Online</b>. You only ' +
            'get job offers while you are online.'),
          rows.length ? payTable(rows) : '',
          rows.length
            ? p('<span style="font-size:13px;color:#5A7184;">The right-hand ' +
                'column is your money. Deicer pays extra on top.</span>')
            : '',
          p(BANK_NOTE),
          button(SIGNUP_URL, 'Set up your payouts'),
          p('Welcome aboard. Reply to this email any time — a real person reads it.'),
        ]
        : [
          p('Your SnowServ application has been approved — you are on the roster ' +
            'for this winter.'),
          p('There is nothing you need to do in the app today. It does not snow ' +
            'in the summer, and we will not send you job offers until it does.'),
          p('<b>The last thing to set up is your bank information</b>, so you get ' +
            'paid without a delay once the work starts. It takes about five ' +
            'minutes on Stripe\'s page, and you can do it whenever you are ready ' +
            '— now, or the week before the first storm. Your call.'),
          rows.length ? payTable(rows) : '',
          rows.length
            ? p('<span style="font-size:13px;color:#5A7184;">The right-hand ' +
                'column is your money. Deicer pays extra on top. These are this ' +
                'season\'s rates.</span>')
            : '',
          p(BANK_NOTE),
          button(SIGNUP_URL, 'Set up your payouts'),
          p('When the first storm is on the way we will email you and send a ' +
            'notification. That is when you go online.'),
          p('Welcome aboard. Reply to this email any time — a real person reads it.'),
        ]).join(''))
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
            'one hour. If it has already expired by the time you get to it, ' +
            'just reply to this email and I will send you a fresh one — it ' +
            'takes me a second.</span>'),
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
          p(inSnowSeason()
            ? 'Finish those and you can go online and start taking jobs.'
            : 'No rush on the timing — it does not snow yet. We will email you ' +
              'before the first storm, and that is when the work starts.'),
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
      await fetch(`${supabaseUrl}/rest/v1/provider_leads?id=eq.${lead_id}`, {
        method: 'PATCH',
        headers: { ...svc, 'Content-Type': 'application/json' },
        body: JSON.stringify({ status: 'contacted' }),
      })
    }

    return json({ sent: 1, to })
  } catch (e: unknown) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500)
  }
})
