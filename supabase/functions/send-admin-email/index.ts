import { shell } from '../_shared/email_shell.ts'

// Free-form email, composed in the admin panel, sent AS SnowServ.
//
// Why this exists: every other path out of the admin panel was a mailto:, which
// composes from whatever account the admin's mail app defaults to (Vince's
// personal Yahoo showed up in the From line of a provider email), carries no
// branding, and leaves no record anywhere he can read. The templated sends were
// already moved server-side; this covers everyone else — a customer who signed
// up on the wrong side, a one-off reply — without going back to copy-and-paste.
//
// RELAY SAFETY: there is no `to` parameter. The caller names a PERSON BY ID and
// the address is resolved here from our own tables, so even a stolen admin
// session can only mail people who are already in the system. That is the same
// bar send-lead-email holds, and it is the reason not to accept a raw address
// "just for convenience".
//
// AUTH: admin only, verified against profiles.is_admin from the caller's token.

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

const esc = (s: string) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

// Plain text in, branded HTML out. The admin types the way he'd type an email —
// blank line between paragraphs — and never has to think about markup. Escaped
// first, so a stray '<' in a typed message can't break the layout.
const paragraphs = (text: string) =>
  esc(text)
    .split(/\n{2,}/)
    .map((block) => block.trim())
    .filter((block) => block.length > 0)
    .map(
      (block) =>
        `<p style="margin:0 0 14px;font-size:15px;line-height:1.55;color:#15242F;">${
          block.replace(/\n/g, '<br>')
        }</p>`,
    )
    .join('')

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
    const callerId = (await userRes.json())?.id
    if (!callerId) return json({ error: 'Unauthorized' }, 401)

    const profs = await (await fetch(
      `${supabaseUrl}/rest/v1/profiles?id=eq.${callerId}&select=is_admin`,
      { headers: svc })).json()
    if (!Array.isArray(profs) || profs[0]?.is_admin !== true) {
      return json({ error: 'Forbidden — admins only' }, 403)
    }

    // --- who, and what ------------------------------------------------------
    const { user_id, subject, body, heading } = await req.json()
    if (!user_id) return json({ error: 'user_id required' }, 400)

    const subj = (subject ?? '').toString().trim()
    const text = (body ?? '').toString().trim()
    if (!subj) return json({ error: 'A subject is required' }, 400)
    if (!text) return json({ error: 'The message is empty' }, 400)

    const rows = await (await fetch(
      `${supabaseUrl}/rest/v1/users?id=eq.${user_id}&select=name,email`,
      { headers: svc })).json()
    const user = Array.isArray(rows) ? rows[0] : null
    if (!user) return json({ error: 'User not found' }, 404)

    const to = (user.email ?? '').toString().trim()
    if (!to) return json({ error: 'No email address on file' }, 400)

    const first = (user.name ?? '').toString().trim().split(/\s+/)[0] ?? ''
    const head = (heading ?? '').toString().trim() ||
      (first ? `Hi ${first}` : 'A note from SnowServ')

    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: FROM,
        to: [to],
        reply_to: REPLY_TO,
        // Their reply goes to support@; this BCC means the OUTGOING half is in
        // the same mailbox, so the thread reads as a conversation instead of
        // half a conversation.
        bcc: [REPLY_TO],
        subject: subj,
        html: shell(esc(head), paragraphs(text)),
      }),
    })
    if (!res.ok) {
      const detail = await res.text().catch(() => '')
      console.error('Resend send failed', res.status, detail)
      return json({ error: 'Send failed', status: res.status }, 502)
    }

    // Logged only AFTER Resend confirms, so the history can never show a
    // message that never went out. Best-effort: a logging failure must not
    // report a delivered email as failed and invite a duplicate send.
    try {
      await fetch(`${supabaseUrl}/rest/v1/email_log`, {
        method: 'POST',
        headers: { ...svc, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          to_email: to,
          subject: subj,
          body: text,
          user_id,
          template: 'admin_freeform',
          sent_by: callerId,
        }),
      })
    } catch (_) { /* the mail is already sent; nothing to undo */ }

    return json({ sent: 1, to })
  } catch (e: unknown) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500)
  }
})
