import { shell } from '../_shared/email_shell.ts'

// Sends recruiting mail as real HTML, with a real button, to either:
//   { lead_id }     — a provider_leads row (came in via the website form), or
//   { provider_id } — a signup stuck at registration_status='incomplete'
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
    const isStalledSignup = !lead_id

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
    }
    if (!to) return json({ error: 'No email address on file' }, 400)

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

    const heading = isStalledSignup
      ? (first ? `Hi ${first} — you're almost done` : 'You\'re almost done')
      : (first ? `Hi ${first} — let's get you plowing` : 'Let\'s get you plowing')

    const opening = isStalledSignup
      ? p('You created a SnowServ provider account but did not get to finish ' +
          'setting it up. If something got in the way — anything confusing or ' +
          'broken — just reply and tell me; I would genuinely like to know.') +
        p('There is not much left. You add your equipment, sign the agreement, ' +
          'and connect a bank account for payouts. About five minutes.')
      : p('Thanks for signing up to plow with SnowServ. We\'re a snow removal app ' +
          'launching in Yonkers this winter — customers order a driveway or ' +
          'sidewalk from their phone, and the job goes to the nearest available ' +
          'provider.')

    const html = shell(heading, [
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

    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: FROM,
        to: [to],
        reply_to: REPLY_TO,
        subject: isStalledSignup
          ? 'Finishing your SnowServ provider account'
          : 'Plowing with SnowServ this winter',
        html,
      }),
    })
    if (!res.ok) {
      const detail = await res.text().catch(() => '')
      console.error('Resend send failed', res.status, detail)
      return json({ error: 'Send failed', status: res.status }, 502)
    }

    // Record the send only after Resend confirms, so a failure never leaves
    // someone looking like they've been contacted when nothing went out.
    if (isStalledSignup) {
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
