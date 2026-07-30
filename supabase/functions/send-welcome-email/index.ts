import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Sends the one-time welcome email after a user CONFIRMS their address (not at
// signup — otherwise two emails race each other and the welcome arrives before
// the account is usable). Separate customer and provider versions.
//
// AUTH MODEL: verify_jwt is off, because the caller is a pg trigger going through
// pg_net, which can't present a Supabase JWT (same constraint as notify-dispatch).
// That makes this URL publicly reachable, so the real guard is IDEMPOTENCY:
// profiles.welcome_email_sent_at is stamped before we send, and a second call for
// the same user is refused. Worst case for an attacker who guesses a user UUID is
// causing at most ONE welcome email that the user was already going to receive —
// not an email bomb.

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const FROM = 'SnowServ <noreply@send.snowserv.app>'
const REPLY_TO = 'support@snowserv.app'

// Shared shell. Same email-HTML constraints as the Supabase Auth templates in
// docs/email_templates/: tables, inline styles, explicit light color-scheme so a
// dark-mode client can't invert it into dark-on-dark.
function shell(heading: string, bodyHtml: string): string {
  return `<div style="background-color:#F0F6FF;margin:0;padding:24px 12px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color-scheme:only light;supported-color-schemes:only light;">
  <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="max-width:600px;margin:0 auto;background-color:#FFFFFF;border-radius:12px;border:1px solid #E2ECF6;">
    <tr><td bgcolor="#0D1B2A" style="background-color:#0D1B2A;padding:28px 32px;border-radius:12px 12px 0 0;text-align:center;">
      <div style="font-size:24px;font-weight:700;color:#FFFFFF;letter-spacing:-0.3px;">&#10052;&#65039; SnowServ</div>
      <div style="font-size:13px;color:#B8D4F0;padding-top:4px;">Snow removal, on demand</div>
    </td></tr>
    <tr><td style="padding:32px;background-color:#FFFFFF;color:#15242F;">
      <h1 style="margin:0 0 16px;font-size:21px;font-weight:700;color:#0D1B2A;">${heading}</h1>
      ${bodyHtml}
    </td></tr>
    <tr><td bgcolor="#F7FBFF" style="background-color:#F7FBFF;padding:18px 32px;border-radius:0 0 12px 12px;border-top:1px solid #E2ECF6;text-align:center;">
      <p style="margin:0;font-size:12px;line-height:1.6;color:#5A7184;">
        Questions? <a href="mailto:support@snowserv.app" style="color:#1565C0;text-decoration:none;">support@snowserv.app</a><br>
        SnowServ &middot; Yonkers, NY
      </p>
    </td></tr>
  </table>
</div>`
}

const p = (t: string) =>
  `<p style="margin:0 0 14px;font-size:15px;line-height:1.55;color:#15242F;">${t}</p>`
const li = (t: string) =>
  `<li style="margin:0 0 8px;font-size:15px;line-height:1.5;color:#15242F;">${t}</li>`
const ul = (items: string[]) =>
  `<ul style="margin:0 0 16px;padding-left:20px;">${items.join('')}</ul>`

function customerEmail(name: string) {
  const hi = name ? `Hi ${name}, welcome` : 'Welcome'
  return {
    subject: 'Welcome to SnowServ',
    html: shell(`${hi} to SnowServ`, [
      p('Your account is confirmed and ready. Here\'s how it works:'),
      ul([
        li('<b>Add your address</b>, then pick what you need — sidewalk, driveway, or both. Salting is an optional add-on.'),
        li('<b>You\'re not charged when you order.</b> We place a temporary hold on your card. It only becomes a real charge when a provider actually starts the work.'),
        li('<b>Cancel before work starts and the hold is released</b> — no charge at all.'),
        li('<b>Your provider photographs the finished job</b>, so you can see the work even if you weren\'t home.'),
      ]),
      p('Pricing depends on your area, and during a storm prices rise with snow depth. You\'ll always see the exact total before you confirm.'),
      p('<a href="mailto:support@snowserv.app" style="color:#1565C0;">Email us</a> any time — a real person reads it.'),
    ].join('')),
  }
}

function providerEmail(name: string) {
  const hi = name ? `Hi ${name}, welcome` : 'Welcome'
  return {
    subject: 'Welcome to SnowServ — what happens next',
    html: shell(`${hi} to SnowServ`, [
      p('Thanks for signing up to work with us. Here\'s what to expect:'),
      ul([
        li('<b>Approval comes first.</b> We review your registration and documents before you can take jobs. You\'ll be notified when you\'re approved.'),
        li('<b>You keep 75% of every job.</b> No fee to join, nothing deducted for equipment or fuel.'),
        li('<b>Payouts run on a 7-day rolling batch</b> to the bank account you connect through Stripe. Set that up in the app before your first job so nothing is held up.'),
        li('<b>Jobs are matched to your equipment.</b> Tell us whether you run a shovel, snowblower, or plow — large driveways are routed to the gear that can handle them.'),
        li('<b>You choose when you work.</b> Go online to receive offers, offline when you\'re done. You can decline any job.'),
      ]),
      p('Two things that protect you: take a photo <b>before</b> you start (optional, but it settles disputes fast), and a live completion photo is required when you finish.'),
      p('Your agreement with us includes a non-solicitation clause — SnowServ customers stay on SnowServ. It\'s in the app under your account menu.'),
      p('<a href="mailto:support@snowserv.app" style="color:#1565C0;">Email us</a> with any question.'),
    ].join('')),
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  try {
    const apiKey = Deno.env.get('RESEND_API_KEY')
    if (!apiKey) {
      // Same shape as support-draft: a clear "not wired up yet" rather than a
      // confusing 500, so this can ship before the Resend account exists.
      return new Response(JSON.stringify({ error: 'RESEND_API_KEY not configured' }),
        { status: 503, headers: { ...cors, 'Content-Type': 'application/json' } })
    }

    const { user_id } = await req.json()
    if (!user_id) {
      return new Response(JSON.stringify({ error: 'user_id required' }), { status: 400, headers: cors })
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)

    const { data: profile } = await supabase
      .from('profiles')
      .select('id, role, full_name, welcome_email_sent_at')
      .eq('id', user_id)
      .maybeSingle()
    if (!profile) {
      return new Response(JSON.stringify({ error: 'Profile not found' }), { status: 404, headers: cors })
    }
    // Idempotency = the abuse guard. Never send twice, no matter who calls.
    if (profile.welcome_email_sent_at) {
      return new Response(JSON.stringify({ skipped: true, reason: 'already sent' }),
        { headers: { ...cors, 'Content-Type': 'application/json' } })
    }

    const { data: userRow } = await supabase
      .from('users').select('email, name').eq('id', user_id).maybeSingle()
    const email = userRow?.email
    if (!email) {
      return new Response(JSON.stringify({ error: 'No email on file' }), { status: 404, headers: cors })
    }

    const name = (profile.full_name ?? userRow?.name ?? '').toString().split(' ')[0]
    const msg = profile.role === 'provider' ? providerEmail(name) : customerEmail(name)

    // Claim the send BEFORE calling Resend. Two triggers firing at once would
    // otherwise both pass the check above and double-send; losing an email to a
    // Resend outage is better than mailing someone twice.
    const { error: claimErr } = await supabase
      .from('profiles')
      .update({ welcome_email_sent_at: new Date().toISOString() })
      .eq('id', user_id)
      .is('welcome_email_sent_at', null)
    if (claimErr) {
      return new Response(JSON.stringify({ error: 'Could not claim send' }), { status: 500, headers: cors })
    }

    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: FROM, to: [email], reply_to: REPLY_TO,
        subject: msg.subject, html: msg.html,
      }),
    })
    if (!res.ok) {
      const detail = await res.text().catch(() => '')
      // Release the claim so a retry can still deliver it.
      await supabase.from('profiles')
        .update({ welcome_email_sent_at: null }).eq('id', user_id)
      console.error('Resend send failed', res.status, detail)
      return new Response(JSON.stringify({ error: 'Send failed', status: res.status }),
        { status: 502, headers: { ...cors, 'Content-Type': 'application/json' } })
    }

    return new Response(JSON.stringify({ sent: 1, role: profile.role ?? 'customer' }),
      { headers: { ...cors, 'Content-Type': 'application/json' } })
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    return new Response(JSON.stringify({ error: msg }), { status: 500, headers: cors })
  }
})
