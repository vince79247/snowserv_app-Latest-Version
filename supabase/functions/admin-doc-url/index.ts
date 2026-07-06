// Returns a short-lived signed URL for a file in the PRIVATE provider-documents
// bucket — but only to a caller whose login token belongs to an admin
// (profiles.is_admin = true), verified server-side. Since the bucket has no
// client read access, this service-role function is the only way to view a
// provider's license/insurance, so those docs are reachable by admins only —
// not customers, not other providers, not the public.
Deno.serve(async (req: Request) => {
  try {
    const { path } = await req.json()
    if (!path) {
      return new Response(JSON.stringify({ error: 'Missing path' }), { status: 400 })
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!

    // Identify the caller from their login token, then require is_admin.
    const token = (req.headers.get('Authorization') ?? '').replace('Bearer ', '')
    const userRes = await fetch(`${supabaseUrl}/auth/v1/user`, {
      headers: { apikey: anonKey, Authorization: `Bearer ${token}` },
    })
    const user = await userRes.json()
    const userId = user?.id
    if (!userId) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401 })
    }

    const profRes = await fetch(
      `${supabaseUrl}/rest/v1/profiles?id=eq.${userId}&select=is_admin`,
      { headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` } }
    )
    const profs = await profRes.json()
    if (!Array.isArray(profs) || profs[0]?.is_admin !== true) {
      return new Response(JSON.stringify({ error: 'Forbidden — admins only' }), { status: 403 })
    }

    // Accept a bare object path or a legacy full public URL — extract the path.
    let objectPath = String(path)
    const marker = '/provider-documents/'
    const idx = objectPath.indexOf(marker)
    if (idx !== -1) objectPath = objectPath.substring(idx + marker.length)
    objectPath = objectPath.split('?')[0]

    const res = await fetch(
      `${supabaseUrl}/storage/v1/object/sign/provider-documents/${objectPath}`,
      {
        method: 'POST',
        headers: {
          apikey: serviceKey,
          Authorization: `Bearer ${serviceKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ expiresIn: 3600 }),
      }
    )
    const data = await res.json()
    if (data.error || !data.signedURL) {
      return new Response(
        JSON.stringify({ error: data.error ?? data.message ?? 'Could not sign URL' }),
        { status: 400 }
      )
    }

    return new Response(
      JSON.stringify({ signed_url: `${supabaseUrl}/storage/v1${data.signedURL}` }),
      { headers: { 'Content-Type': 'application/json' } }
    )
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    return new Response(JSON.stringify({ error: msg }), { status: 500 })
  }
})
