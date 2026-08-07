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

const payTable = (rows: Array<[string, number]>) =>
  `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 18px;width:100%;max-width:340px;">
     ${rows.map(([label, amt], i) => `
     <tr>
       <td style="padding:9px 12px;font-size:15px;color:#15242F;background:${i % 2 ? '#FFFFFF' : '#F0F6FF'};border-radius:4px 0 0 4px;">${label}</td>
       <td align="right" style="padding:9px 12px;font-size:15px;font-weight:bold;color:#15242F;background:${i % 2 ? '#FFFFFF' : '#F0F6FF'};border-radius:0 4px 4px 0;">$${amt}</td>
     </tr>`).join('')}
   </table>`

const esc = (s: string) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

const BANK_NOTE =
  '<b>Your bank details go to Stripe, not to us.</b> You set up payouts on ' +
  'Stripe\'s own secure page — SnowServ never sees or stores your bank account ' +
  'or Social Security number. Stripe pays you directly and issues your 1099 at ' +
  'the end of the year.'

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
    const { lead_id, provider_id } = await req.json()
    if (!lead_id && !provider_id) {
      return json({ error: 'lead_id or provider_id required' }, 400)
    }

    let to = ''
    let firstName = ''
    let leadStatus: string | null = null
    let regStatus: string | null = null

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
        `${supabaseUrl}/rest/v1/providers?id=eq.${provider_id}&select=id,registration_status,users!inner(name,email)`,
        { headers: svc })).json()
      const prov = Array.isArray(rows) ? rows[0] : null
      if (!prov) return json({ error: 'Provider not found' }, 404)
      to = (prov.users?.email ?? '').toString().trim()
      firstName = (prov.users?.name ?? '').toString().trim().split(/\s+/)[0] ?? ''
      regStatus = (prov.registration_status ?? '').toString()
    }
    if (!to) return json({ error: 'No email address on file' }, 400)

    // A provider row is TWO different conversations, and sending the wrong one
    // is worse than sending nothing: telling somebody who just submitted a
    // complete application to "finish your registration" reads as though we
    // lost it. Branch on the actual status, not on "did the caller pass a
    // provider_id".
    const isPendingReview = !lead_id && regStatus === 'pending_review'
    const isStalledSignup = !lead_id && !isPendingReview

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

    const rows: Array<[string, number]> = []
    const add = (label: string, raw: unknown) => {
      const v = Number(raw)
      if (Number.isFinite(v) && v > 0) rows.push([label, Math.round(v * providerPct)])
    }
    if (zone) {
      add('Sidewalk', zone.price_sidewalk)
      add('Driveway', zone.price_driveway)
      add('Sidewalk + driveway', zone.price_both)
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

    const heading = isPendingReview
      ? (first ? `Hi ${first} — we have your application` : 'We have your application')
      : isStalledSignup
        ? (first ? `Hi ${first} — you're almost done` : 'You\'re almost done')
        : outOfArea
          ? (first ? `Hi ${first} — not your area yet` : 'Not your area yet')
          : (first ? `Hi ${first} — let's get you plowing` : 'Let\'s get you plowing')

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
      : p('Thanks for signing up to plow with SnowServ. We\'re a snow removal app ' +
          'launching in Yonkers this winter — customers order a driveway or ' +
          'sidewalk from their phone, and the job goes to the nearest available ' +
          'provider.')

    // Already applied and waiting on us. No pay table and no recruiting pitch —
    // they have seen the rates; what they want to know is that a human has it
    // and what happens next. The one useful action left is payouts, which is
    // the step that most often holds up a first payment.
    const html = isPendingReview
      ? shell(heading, [
          p('Thanks for finishing your SnowServ registration. We have it, and ' +
            'we are reviewing it now.'),
          p('You will hear from us as soon as you are approved. After that you ' +
            'can go online in the app and start taking jobs.'),
          p('<b>One thing worth doing while you wait:</b> connect your bank ' +
            'account for payouts, so nothing holds up your first payment.'),
          p(BANK_NOTE),
          button(SIGNUP_URL, 'Set up your payouts'),
          p('Just reply to this email if you have any questions — a real person ' +
            'reads it.'),
        ].join(''))
      : outOfArea
      ? shell(heading, [
          p('Thanks for your interest in plowing with SnowServ. Straight answer: ' +
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
          p(`<b>You keep ${pct}% of every job.</b>`),
          rows.length ? payTable(rows) : '',
          p('Deicer pays extra on top of those. You choose which jobs you take and ' +
            'you keep your own schedule.'),
          p('No sign-up fees, no monthly fees, no contract.'),
          p(BANK_NOTE),
          button(SIGNUP_URL, isStalledSignup ? 'Finish your registration' : 'Create your account'),
          p('Just reply to this email if you have any questions — a real person reads it.'),
        ].join(''))

    const template = isPendingReview
      ? 'pending_review'
      : isStalledSignup
        ? 'stalled_signup'
        : outOfArea
          ? 'out_of_area'
          : 'lead_new'

    const subject = isPendingReview
      ? 'We have your SnowServ application'
      : isStalledSignup
        ? 'Finishing your SnowServ provider account'
        : outOfArea
          ? 'SnowServ — not your area yet, but you are on the list'
          : 'Plowing with SnowServ this winter'

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
          body: html,
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
