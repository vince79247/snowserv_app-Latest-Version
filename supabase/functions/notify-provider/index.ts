import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const PROJECT_ID = 'snowserv-a5a29'

async function getAccessToken(serviceAccount: any): Promise<string> {
  const now = Math.floor(Date.now() / 1000)
  const headerB64 = btoa(JSON.stringify({ alg: 'RS256', typ: 'JWT' })).replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '')
  const payloadB64 = btoa(JSON.stringify({
    iss: serviceAccount.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    exp: now + 3600,
    iat: now,
  })).replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '')
  const signingInput = `${headerB64}.${payloadB64}`
  const pemContents = serviceAccount.private_key.replace('-----BEGIN PRIVATE KEY-----', '').replace('-----END PRIVATE KEY-----', '').replace(/\s/g, '')
  const binaryKey = Uint8Array.from(atob(pemContents), (c: string) => c.charCodeAt(0))
  const cryptoKey = await crypto.subtle.importKey('pkcs8', binaryKey, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign'])
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', cryptoKey, new TextEncoder().encode(signingInput))
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(signature))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '')
  const jwt = `${signingInput}.${sigB64}`
  const tokenRes = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${jwt}`,
  })
  const tokenData = await tokenRes.json()
  return tokenData.access_token
}

async function sendNotification(accessToken: string, fcmToken: string, title: string, body: string, urgent = true): Promise<{ ok: boolean; code?: string }> {
  // Time-Sensitive rings through Focus/Do Not Disturb. Right for "a job just
  // landed on you" / "your customer cancelled"; wrong for a dispute outcome,
  // which must not wake a provider at 3am. Only work-now pushes get it.
  const aps: Record<string, unknown> = { alert: { title, body }, sound: 'default' }
  if (urgent) aps['interruption-level'] = 'time-sensitive'
  const res = await fetch(`https://fcm.googleapis.com/v1/projects/${PROJECT_ID}/messages:send`, {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      message: {
        token: fcmToken,
        notification: { title, body },
        apns: {
          headers: { 'apns-priority': '10', 'apns-push-type': 'alert' },
          // alert set explicitly — a partial aps payload can strip the
          // auto-generated alert text (see notify-dispatch).
          payload: { aps },
        },
      },
    }),
  })
  if (res.ok) return { ok: true }
  const err = await res.json().catch(() => ({}))
  const code = err?.error?.details?.[0]?.errorCode ?? err?.error?.status ?? String(res.status)
  console.error(`FCM send failed: HTTP ${res.status} ${code}`, JSON.stringify(err?.error ?? {}))
  return { ok: false, code }
}

function getNotificationContent(status: string): { title: string; body: string; urgent?: boolean } | null {
  switch (status) {
    case 'cancelled':
      return { title: 'Job Cancelled', body: 'The customer cancelled this job.' }
    case 'auto_assigned':
      return { title: 'New Job Assigned', body: 'Auto-accept picked up a job for you — open the app to view it.' }
    case 'admin_assigned':
      return { title: 'New Job Assigned', body: 'A job has been assigned to you — open the app to view it.' }
    // Approved to work. Until this existed, approving somebody told them
    // nothing at all — they could sit approved for weeks and never know to go
    // online, which wastes the entire recruiting effort that got them here.
    case 'approved':
      return {
        title: "You're approved to work ❄️",
        body: 'Your SnowServ application was approved. Open the app and go online to start getting jobs.',
        urgent: true,
      }
    // Not a rejection, and the wording must not read like one — they are one
    // small fix away and their answers are all still there.
    case 'needs_attention':
      return {
        title: 'One thing to fix',
        body: 'Your SnowServ application needs one small correction. Open the app to see what it is.',
        urgent: false,
      }
    // Outcome of a "Report a problem" the PROVIDER filed. Same wording rules as
    // notify-customer: no internal detail, point them at support to reply.
    case 'dispute_resolved':
      return {
        title: 'We resolved your report',
        body: 'We reviewed the problem you reported and took action. Questions? Email support@snowserv.app.',
        urgent: false,
      }
    case 'dispute_closed':
      return {
        title: 'Update on your report',
        body: 'We reviewed the problem you reported and closed it without further action. ' +
              'If you disagree, reply to us at support@snowserv.app.',
        urgent: false,
      }
    default:
      return null
  }
}

// CORS: the app runs on WEB too — the browser preflights functions.invoke,
// so answer OPTIONS and stamp responses or browser calls are blocked.
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  try {
    // provider_id is an alternative to job_id, for messages about the PERSON
    // rather than about a job — approval being the first of them. Every earlier
    // status here was job-scoped, so the provider could only ever be reached by
    // way of a job they were already on.
    const { job_id, provider_id, status } = await req.json()

    const notification = getNotificationContent(status)
    if (!notification) return new Response(JSON.stringify({ skipped: true }), { status: 200, headers: cors })

    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)

    let providerId: string | null = provider_id ?? null
    if (!providerId) {
      const { data: job } = await supabase
        .from('jobs')
        .select('provider_id')
        .eq('id', job_id)
        .single()
      if (!job?.provider_id) return new Response(JSON.stringify({ sent: 0 }), { status: 200, headers: cors })
      providerId = job.provider_id
    }

    const { data: provider } = await supabase
      .from('providers')
      .select('user_id')
      .eq('id', providerId)
      .single()
    if (!provider?.user_id) return new Response(JSON.stringify({ sent: 0 }), { status: 200, headers: cors })

    const { data: profile } = await supabase
      .from('profiles')
      .select('fcm_token')
      .eq('id', provider.user_id)
      .single()
    if (!profile?.fcm_token) return new Response(JSON.stringify({ sent: 0 }), { status: 200, headers: cors })

    const serviceAccount = JSON.parse(Deno.env.get('FIREBASE_SERVICE_ACCOUNT')!)
    const accessToken = await getAccessToken(serviceAccount)
    const result = await sendNotification(
      accessToken, profile.fcm_token, notification.title, notification.body, notification.urgent !== false)

    // Only clear a token Firebase says is genuinely dead (UNREGISTERED). A config
    // error like THIRD_PARTY_AUTH_ERROR means a VALID token we couldn't reach — keep
    // it, and report the real failure instead of a fake sent:1.
    if (!result.ok && result.code === 'UNREGISTERED') {
      await supabase.from('profiles').update({ fcm_token: null }).eq('id', provider.user_id)
    }

    return new Response(JSON.stringify(result.ok ? { sent: 1 } : { sent: 0, error: result.code }), { headers: { ...cors, 'Content-Type': 'application/json' } })
  } catch (e: any) {
    return new Response(JSON.stringify({ error: e.message }), { status: 500, headers: cors })
  }
})
