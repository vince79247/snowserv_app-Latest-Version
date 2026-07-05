// Returns a short-lived signed URL for a file in the PRIVATE provider-documents
// bucket — but only to a caller that presents the correct admin password
// (verified server-side against the ADMIN_PASSWORD secret). Since the bucket has
// no client read access, this service-role function is the only way to view a
// provider's license/insurance, so those documents are reachable by the admin
// only — not customers, not other providers, not the public.
Deno.serve(async (req: Request) => {
  try {
    const { admin_password, path } = await req.json()

    const adminPw = Deno.env.get('ADMIN_PASSWORD')
    if (!adminPw || admin_password !== adminPw) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401 })
    }
    if (!path) {
      return new Response(JSON.stringify({ error: 'Missing path' }), { status: 400 })
    }

    // Accept either a bare object path or a legacy full public URL — extract the
    // path after the bucket segment so old records still resolve.
    let objectPath = String(path)
    const marker = '/provider-documents/'
    const idx = objectPath.indexOf(marker)
    if (idx !== -1) objectPath = objectPath.substring(idx + marker.length)
    objectPath = objectPath.split('?')[0]

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

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

    // signedURL comes back as a relative path (/object/sign/...?token=...).
    const signedUrl = `${supabaseUrl}/storage/v1${data.signedURL}`
    return new Response(
      JSON.stringify({ signed_url: signedUrl }),
      { headers: { 'Content-Type': 'application/json' } }
    )
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    return new Response(JSON.stringify({ error: msg }), { status: 500 })
  }
})
