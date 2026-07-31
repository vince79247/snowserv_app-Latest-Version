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

// Copy + HTML live in emails.ts so the preview script renders the REAL message.
import { customerEmail, providerEmail } from './emails.ts'

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
