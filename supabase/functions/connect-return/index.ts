// Landing page Stripe sends the provider back to after (or during) Express
// payout onboarding — both the account link's return_url and refresh_url point
// here. Same platform limitation as auth-confirmed / checkout-return: Supabase
// forces text/plain + a CSP sandbox on HTML from *.supabase.co edge functions,
// so we return clean PLAIN TEXT. verify_jwt MUST be false — it's a top-level
// browser navigation from Stripe with no Authorization header.
//
// Stripe uses two states:
//   return  — the provider finished (or stepped away from) the hosted flow.
//   refresh — the one-time link expired before completion; they reopen from app.
// We can't fully distinguish "done" from "abandoned" here (the app re-checks the
// real status via connect-status), so the copy is true either way.

Deno.serve((req: Request) => {
  const state = new URL(req.url).searchParams.get('state')
  const body = state === 'refresh'
    ? 'That payout-setup link expired.\n\n' +
      'Head back to the SnowServ app and tap “Set up payouts” again to get a ' +
      'fresh link.\n\n' +
      'Need help? support@snowserv.app\n\n' +
      'You can close this window now.'
    : 'Thanks 👍\n\n' +
      'Head back to the SnowServ app — your payout status will update there.\n\n' +
      'If it still says setup isn’t finished, tap “Set up payouts” again to ' +
      'complete the remaining steps.\n\n' +
      'Need help? support@snowserv.app\n\n' +
      'You can close this window now.'

  return new Response(body, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  })
})
