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

async function sendNotification(accessToken: string, fcmToken: string, title: string, body: string): Promise<{ ok: boolean; code?: string }> {
  const res = await fetch(`https://fcm.googleapis.com/v1/projects/${PROJECT_ID}/messages:send`, {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
    // alert set explicitly in aps — a partial aps payload can strip the
    // auto-generated alert text (see notify-dispatch).
    body: JSON.stringify({ message: { token: fcmToken, notification: { title, body }, apns: { payload: { aps: { alert: { title, body }, sound: 'default' } } } } }),
  })
  if (res.ok) return { ok: true }
  const err = await res.json().catch(() => ({}))
  const code = err?.error?.details?.[0]?.errorCode ?? err?.error?.status ?? String(res.status)
  console.error(`FCM send failed: HTTP ${res.status} ${code}`, JSON.stringify(err?.error ?? {}))
  return { ok: false, code }
}

function getNotificationContent(
  status: string,
  opts?: { amountUsd?: number | null },
): { title: string; body: string } | null {
  switch (status) {
    case 'assigned':
      return { title: 'Provider Assigned!', body: 'A provider has accepted your job and is on the way.' }
    case 'in_progress':
      return { title: 'Work Has Started!', body: 'Your provider has started working on your property.' }
    case 'completed':
      return { title: 'Job Complete!', body: 'Your snow removal is done. Tap to view your receipt.' }
    case 'provider_cancelled':
      return { title: 'Provider Cancelled', body: 'Your provider cancelled. We\'re finding you a new one.' }
    case 'provider_cancelled_after_start':
      // Post-start cancel: the card was already charged when work started, and
      // the job re-dispatches still paid — be honest about the money state.
      return {
        title: 'Provider Had to Cancel',
        body: 'Your provider couldn\'t finish — we\'re finding you a new one at no extra charge. ' +
              'You won\'t be charged again. Prefer a full refund? Just cancel the job in the app.',
      }
    // Outcome of a "Report a problem" the CUSTOMER filed. Deliberately vague on
    // what we did — the admin's resolution note can contain internal detail and
    // is never pushed to a phone.
    // A job nobody has picked up yet. Honest, not cheery: they have a hold on
    // their card and a spinner on their screen, and the useful thing to tell
    // them is that they are not trapped.
    case 'still_searching':
      return {
        title: 'Still finding you a provider',
        body: 'It\'s taking longer than usual — we\'re still looking. You can cancel any time for a full release of the hold.',
      }
    case 'no_provider_found':
      return {
        title: 'We couldn\'t find a provider',
        body: 'Nobody was available for your job, so we\'ve cancelled it and released the hold on your card. You were not charged. Sorry about that.',
      }
    case 'storm_booking_triggered': {
      // SAY THE NUMBER. This is the one job the customer never approved in the
      // moment: it fires while they are asleep and authorizes their card
      // off-session. A notification that doesn't name the amount is how a
      // reasonable person ends up disputing the charge instead of asking about
      // it — they wake to a hold they never saw agreed to. It is still only a
      // hold until a provider starts, and cancelling before then releases it in
      // full, which is worth the extra sentence at 4am.
      const amt = opts?.amountUsd
      const money = typeof amt === 'number' && amt > 0 ? `$${Math.round(amt)}` : null
      return {
        title: 'Snow stopped — your job is booked ❄️',
        body: money
          ? `We're sending a provider to clear your property. ${money} is on hold — you're only charged once they start, so you can still cancel free in the app.`
          : 'Your storm booking just fired. We\'re sending a provider to clear your property.',
      }
    }
    case 'storm_booking_failed':
      return {
        title: 'Storm booking needs attention',
        body: 'We couldn\'t authorize your card for your storm booking. Open the app to update it.',
      }
    case 'dispute_resolved':
      return {
        title: 'We resolved your report',
        body: 'We reviewed the problem you reported and took action. Questions? Email support@snowserv.app.',
      }
    case 'dispute_closed':
      return {
        title: 'Update on your report',
        body: 'We reviewed the problem you reported and closed it without further action. ' +
              'If you disagree, reply to us at support@snowserv.app.',
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
    const { job_id, user_id, status } = await req.json()

    // Cheap check first: an unknown status does no database work at all.
    if (!getNotificationContent(status)) {
      return new Response(JSON.stringify({ skipped: true }), { status: 200, headers: cors })
    }

    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)

    // user_id is an alternative to job_id, for messages about the PERSON rather
    // than a job — a storm booking whose card was declined has no job to point
    // at, because failing to authorize is precisely why no job exists.
    let customerId: string | null = user_id ?? null
    let amountUsd: number | null = null
    if (!customerId) {
      const { data: job, error: jobError } = await supabase
          .from('jobs').select('customer_id, final_price').eq('id', job_id).single()
      if (!job) return new Response(JSON.stringify({ error: 'Job not found', details: jobError }), { status: 404, headers: cors })
      customerId = job.customer_id
      amountUsd = job.final_price != null ? Number(job.final_price) : null
    }

    // Rebuilt with the amount now that the job is loaded — see
    // storm_booking_triggered, which must name the sum it just put on hold.
    const notification = getNotificationContent(status, { amountUsd })!

    const { data: profile } = await supabase.from('profiles').select('fcm_token').eq('id', customerId).single()
    if (!profile?.fcm_token) return new Response(JSON.stringify({ sent: 0 }), { status: 200, headers: cors })

    const serviceAccount = JSON.parse(Deno.env.get('FIREBASE_SERVICE_ACCOUNT')!)
    const accessToken = await getAccessToken(serviceAccount)
    const result = await sendNotification(accessToken, profile.fcm_token, notification.title, notification.body)

    // Only clear a genuinely dead token (UNREGISTERED); keep valid tokens on a
    // config error and report the real failure instead of a fake sent:1.
    if (!result.ok && result.code === 'UNREGISTERED') {
      await supabase.from('profiles').update({ fcm_token: null }).eq('id', customerId)
    }

    return new Response(JSON.stringify(result.ok ? { sent: 1 } : { sent: 0, error: result.code }), { headers: { ...cors, 'Content-Type': 'application/json' } })
  } catch (e: any) {
    return new Response(JSON.stringify({ error: e.message }), { status: 500, headers: cors })
  }
})
