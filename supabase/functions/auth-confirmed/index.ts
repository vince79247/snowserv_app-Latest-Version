// Landing page a user lands on after clicking "Confirm your email" in the signup
// email. Supabase verifies the token, then redirects the browser to the project's
// Auth **Site URL** — which was previously misconfigured, so users (and App Store
// reviewers) hit "Safari can't find the server" and the app looked broken.
// Pointing Site URL at this function gives that redirect a real, owned https page.
//
// ⚠️ Same platform limitation as `checkout-return`: Supabase forces
// `Content-Type: text/plain` + a CSP sandbox on HTML served from edge functions on
// the default *.supabase.co domain, so styled HTML renders as raw markup. We
// therefore return clean PLAIN TEXT, which reads fine under that forcing. A
// branded page needs a non-sandboxed host (a Cloudflare page under snowserv.app) —
// tracked separately.
//
// verify_jwt MUST stay false: this is a top-level browser navigation from an email
// link, with no Authorization header.

Deno.serve((req: Request) => {
  const url = new URL(req.url)
  // Supabase appends ?error=... / ?error_description=... when a link is expired or
  // already used — don't tell someone "you're all set" when it actually failed.
  const error = url.searchParams.get('error') ?? url.searchParams.get('error_description')

  const body = error
    ? 'That confirmation link didn’t work\n\n' +
      'It may have expired or already been used.\n\n' +
      'Open the SnowServ app and try signing up or logging in again — ' +
      'we can send you a fresh confirmation email.\n\n' +
      'Need help? support@snowserv.app\n\n' +
      'You can close this window now.'
    : 'Email confirmed ✓\n\n' +
      'Your SnowServ account is all set.\n\n' +
      'Head back to the SnowServ app and log in with your email and password.\n\n' +
      'You can close this window now.'

  return new Response(body, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  })
})
