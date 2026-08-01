import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { shell } from '../_shared/email_shell.ts'

// Email for the two ends of a "Report a problem": we got it, and here's the
// outcome.
//
// WHY EMAIL AND NOT JUST PUSH: resolution was push-only, which was right when
// push was all we had. But push is ephemeral — it needs the app installed and
// notifications enabled, and it's gone once dismissed. "We reviewed your
// complaint and here's what we did" is exactly the kind of message someone needs
// to be able to find again, forward, or reply to. Push stays as the instant ping;
// email is the record.
//
// NO TICKETING SYSTEM: jobs.job_number is already unique, already shown in the
// app and already on the receipt. Inventing a second reference number would give
// the customer two IDs for one problem.
//
// ROUTING: strictly by disputes.filed_by, which a trigger derives from the
// filer's own auth uid. Never guess — mailing a provider's complaint to the
// customer would disclose that a complaint was made about them.

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const FROM = 'SnowServ <noreply@send.snowserv.app>'
const REPLY_TO = 'support@snowserv.app'

const p = (t: string) =>
  `<p style="margin:0 0 14px;font-size:15px;line-height:1.55;color:#15242F;">${t}</p>`

function ref(jobNumber: unknown): string {
  return jobNumber == null ? '' : ` for <b>Job #${jobNumber}</b>`
}

function body(kind: string, jobNumber: unknown, reason: string | null) {
  const r = ref(jobNumber)
  const because = reason ? p(`You told us: <i>${reason}</i>`) : ''
  switch (kind) {
    case 'received':
      return {
        subject: jobNumber == null
          ? 'We received your report'
          : `We received your report — Job #${jobNumber}`,
        html: shell('We’ve got your report', [
          p(`Thanks for letting us know. We’ve received your report${r} and a real person will review it.`),
          because,
          p('We look at every report and follow up with both sides before deciding anything. You don’t need to do anything else right now.'),
          p('If you remember something else that would help, just reply to this email.'),
        ].join('')),
      }
    case 'resolved':
      return {
        subject: jobNumber == null
          ? 'We resolved your report'
          : `We resolved your report — Job #${jobNumber}`,
        html: shell('We resolved your report', [
          p(`We’ve finished reviewing your report${r} and taken action.`),
          // Deliberately vague: the admin's resolution note is internal and can
          // contain detail about the other party that must not be forwarded on.
          p('If you have questions about the outcome, reply to this email and we’ll explain.'),
        ].join('')),
      }
    case 'closed':
      return {
        subject: jobNumber == null
          ? 'Update on your report'
          : `Update on your report — Job #${jobNumber}`,
        html: shell('Update on your report', [
          p(`We’ve reviewed your report${r} and closed it without further action.`),
          p('If you disagree, reply to this email — we’ll take another look. We’d rather hear from you than have you walk away unhappy.'),
        ].join('')),
      }
    default:
      return null
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  try {
    const apiKey = Deno.env.get('RESEND_API_KEY')
    if (!apiKey) {
      return new Response(JSON.stringify({ error: 'RESEND_API_KEY not configured' }),
        { status: 503, headers: { ...cors, 'Content-Type': 'application/json' } })
    }

    const { dispute_id, kind } = await req.json()
    if (!dispute_id || !kind) {
      return new Response(JSON.stringify({ error: 'dispute_id and kind required' }),
        { status: 400, headers: cors })
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)

    const { data: d } = await supabase
      .from('disputes')
      .select('id, job_id, customer_id, provider_id, filed_by, reason, jobs(job_number)')
      .eq('id', dispute_id)
      .maybeSingle()
    if (!d) {
      return new Response(JSON.stringify({ error: 'Dispute not found' }), { status: 404, headers: cors })
    }

    const msg = body(kind, (d.jobs as { job_number?: unknown } | null)?.job_number, d.reason)
    if (!msg) {
      return new Response(JSON.stringify({ skipped: true, reason: 'unknown kind' }),
        { headers: { ...cors, 'Content-Type': 'application/json' } })
    }

    // Who filed it decides who hears about it.
    let userId: string | null = null
    if (d.filed_by === 'provider') {
      const { data: prov } = await supabase
        .from('providers').select('user_id').eq('id', d.provider_id).maybeSingle()
      userId = prov?.user_id ?? null
    } else {
      userId = d.customer_id
    }
    if (!userId) {
      return new Response(JSON.stringify({ sent: 0, reason: 'no recipient' }),
        { headers: { ...cors, 'Content-Type': 'application/json' } })
    }

    const { data: u } = await supabase
      .from('users').select('email').eq('id', userId).maybeSingle()
    if (!u?.email) {
      return new Response(JSON.stringify({ sent: 0, reason: 'no email on file' }),
        { headers: { ...cors, 'Content-Type': 'application/json' } })
    }

    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: FROM, to: [u.email], reply_to: REPLY_TO,
        subject: msg.subject, html: msg.html,
      }),
    })
    if (!res.ok) {
      const detail = await res.text().catch(() => '')
      console.error('Resend dispute email failed', res.status, detail)
      return new Response(JSON.stringify({ error: 'Send failed', status: res.status }),
        { status: 502, headers: { ...cors, 'Content-Type': 'application/json' } })
    }

    return new Response(JSON.stringify({ sent: 1, to_side: d.filed_by ?? 'customer', kind }),
      { headers: { ...cors, 'Content-Type': 'application/json' } })
  } catch (e: unknown) {
    const m = e instanceof Error ? e.message : String(e)
    return new Response(JSON.stringify({ error: m }), { status: 500, headers: cors })
  }
})
