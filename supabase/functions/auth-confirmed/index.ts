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

Deno.serve((_req: Request) => {
  // NOTE: Supabase reports a verify error (expired / already-used link) in the URL
  // FRAGMENT (#error=...), which is never sent to the server — and JS can't read it
  // here either, because Supabase sandboxes edge-function HTML. So this page cannot
  // tell success from failure, and must not falsely claim "confirmed". The copy
  // below is true in BOTH cases: on success you log in; on a dead link the app tells
  // you it's unconfirmed and you sign up again for a fresh one. A branded page that
  // reads the fragment needs a non-sandboxed host (Cloudflare) — tracked separately.
  const body =
    'You’re all set 👍\n\n' +
    'Head back to the SnowServ app and log in with your email and password.\n\n' +
    'If the app says your email still needs confirming, the link may have expired — ' +
    'just sign up again in the app to get a fresh one.\n\n' +
    'Need help? support@snowserv.app\n\n' +
    'You can close this window now.'

  return new Response(body, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  })
})
