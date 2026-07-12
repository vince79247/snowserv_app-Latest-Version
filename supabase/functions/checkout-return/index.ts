// Landing page shown INSIDE the mobile in-app browser after the customer finishes
// (or cancels) Stripe Checkout. The order itself is created server-side by the
// stripe-webhook, so this page is purely a "you're done, close this" confirmation.
//
// ⚠️ PLATFORM LIMITATION: Supabase sandboxes HTML served from edge functions on the
// default *.supabase.co / *.functions.supabase.co domains — it forces
// `Content-Type: text/plain` + `Content-Security-Policy: sandbox` + `nosniff`
// (anti-phishing). A styled HTML page therefore renders as raw markup on-device.
// So we return clean, readable PLAIN TEXT that reads fine under that forcing.
// The user closes the browser with its own built-in "Done" button (no in-page
// button/script can run under the sandbox anyway). A properly styled, branded
// return page needs a NON-sandboxed host (e.g. a Cloudflare page under
// snowserv.app) — tracked as a separate task.
//
// The WEB app does NOT use this (it redirects to its own origin instead).
// verify_jwt MUST stay false — this is a top-level browser navigation from Stripe.

Deno.serve((req: Request) => {
  const url = new URL(req.url)
  const status = url.searchParams.get('status') ?? 'success'
  const success = status !== 'cancel'

  // NOTE: paying here only places an authorization HOLD (capture_method=manual).
  // The card is NOT charged until a provider STARTS the job, so this copy must not
  // say "payment received"/"charged" — that would contradict the hold promise.
  const body = success
    ? "You're all set!\n\n" +
      "Your order is in. Head back to the SnowServ app and we'll find a " +
      "provider near you.\n\n" +
      "Your card is only charged once a provider starts the job.\n\n" +
      "You can close this window now."
    : "Order canceled\n\n" +
      "No charge was made. Head back to the SnowServ app to try again.\n\n" +
      "You can close this window now."

  return new Response(body, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  })
})
