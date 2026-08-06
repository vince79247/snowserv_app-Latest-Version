import { shell } from '../_shared/email_shell.ts'

// Sends the recruiting email to a row in provider_leads — as real HTML, with a
// real "Finish your registration" BUTTON.
//
// Why this exists when the admin panel can already open a mailto: draft: a
// mailto body is plain text by specification. It cannot carry a link, a button,
// or any formatting. A contractor reading a bare URL has to select it, copy it,
// and paste it into a browser, and a share of them simply won't. This sends the
// same message through Resend so the call to action is one tap.
//
// AUTH MODEL: admin only. Unlike send-welcome-email (fired by a pg trigger via
// pg_net, guarded by idempotency), this one mails an arbitrary address on
// demand, so it verifies the CALLER's login token maps to profiles.is_admin —
// the same check admin-doc-url uses. Without that it would be an open relay
// pointed at our own lead list.
//
// PRICES ARE COMPUTED SERVER-SIDE from the live zone row and the live
// commission setting, never passed in by the client and never typed into a
// template. Recruiting copy quoting stale prices has already cost us once
// (2026-08-04, figures ~25% below what we actually pay).

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

    // --- the lead ----------------------------------------------------------
    const { lead_id } = await req.json()
    if (!lead_id) return json({ error: 'lead_id required' }, 400)

    const leads = await (await fetch(
      `${supabaseUrl}/rest/v1/provider_leads?id=eq.${lead_id}&select=id,name,email,status`,
      { headers: svc })).json()
    const lead = Array.isArray(leads) ? leads[0] : null
    if (!lead) return json({ error: 'Lead not found' }, 404)
    const to = (lead.email ?? '').toString().trim()
    if (!to) return json({ error: 'That lead has no email address' }, 400)

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
    const first = esc((lead.name ?? '').toString().trim().split(/\s+/)[0] ?? '')
    const html = shell(first ? `Hi ${first} — let's get you plowing` : "Let's get you plowing", [
      p('Thanks for signing up to plow with SnowServ. We\'re a snow removal app launching in Yonkers this winter — customers order a driveway or sidewalk from their phone, and the job goes to the nearest available provider.'),
      p(`<b>You keep ${Math.round(providerPct * 100)}% of every job.</b>`),
      rows.length ? payTable(rows) : '',
      p('Deicer pays extra on top of those. You choose which jobs you take and you keep your own schedule.'),
      p('No sign-up fees, no monthly fees, no contract. Payouts go straight to your bank.'),
      button(SIGNUP_URL, 'Finish your registration'),
      p('It takes about five minutes. Just reply to this email if you have any questions — a real person reads it.'),
    ].join(''))

    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: FROM,
        to: [to],
        reply_to: REPLY_TO,
        subject: 'Plowing with SnowServ this winter',
        html,
      }),
    })
    if (!res.ok) {
      const detail = await res.text().catch(() => '')
      console.error('Resend send failed', res.status, detail)
      return json({ error: 'Send failed', status: res.status }, 502)
    }

    // Advance the pipeline only after a confirmed send, so a failure never
    // leaves a lead marked contacted when nothing went out.
    if ((lead.status ?? 'new') === 'new') {
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
