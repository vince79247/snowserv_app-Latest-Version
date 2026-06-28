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

async function sendNotification(accessToken: string, fcmToken: string, title: string, body: string): Promise<boolean> {
  const res = await fetch(`https://fcm.googleapis.com/v1/projects/${PROJECT_ID}/messages:send`, {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ message: { token: fcmToken, notification: { title, body }, apns: { payload: { aps: { sound: 'default' } } } } }),
  })
  if (!res.ok) {
    const err = await res.json().catch(() => ({}))
    const code = err?.error?.details?.[0]?.errorCode ?? err?.error?.status
    return code !== 'UNREGISTERED' && code !== 'INVALID_ARGUMENT'
  }
  return true
}

function getNotificationContent(status: string): { title: string; body: string } | null {
  switch (status) {
    case 'cancelled':
      return { title: 'Job Cancelled', body: 'The customer cancelled this job.' }
    default:
      return null
  }
}

Deno.serve(async (req: Request) => {
  try {
    const { job_id, status } = await req.json()

    const notification = getNotificationContent(status)
    if (!notification) return new Response(JSON.stringify({ skipped: true }), { status: 200 })

    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)

    const { data: job } = await supabase
      .from('jobs')
      .select('provider_id')
      .eq('id', job_id)
      .single()
    if (!job?.provider_id) return new Response(JSON.stringify({ sent: 0 }), { status: 200 })

    const { data: provider } = await supabase
      .from('providers')
      .select('user_id')
      .eq('id', job.provider_id)
      .single()
    if (!provider?.user_id) return new Response(JSON.stringify({ sent: 0 }), { status: 200 })

    const { data: profile } = await supabase
      .from('profiles')
      .select('fcm_token')
      .eq('id', provider.user_id)
      .single()
    if (!profile?.fcm_token) return new Response(JSON.stringify({ sent: 0 }), { status: 200 })

    const serviceAccount = JSON.parse(Deno.env.get('FIREBASE_SERVICE_ACCOUNT')!)
    const accessToken = await getAccessToken(serviceAccount)
    const ok = await sendNotification(accessToken, profile.fcm_token, notification.title, notification.body)

    if (!ok) {
      await supabase.from('profiles').update({ fcm_token: null }).eq('id', provider.user_id)
    }

    return new Response(JSON.stringify({ sent: ok ? 1 : 0 }), { headers: { 'Content-Type': 'application/json' } })
  } catch (e: any) {
    return new Response(JSON.stringify({ error: e.message }), { status: 500 })
  }
})
