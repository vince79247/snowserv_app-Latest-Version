// Tiny HTML landing page shown INSIDE the mobile in-app browser after the
// customer finishes (or cancels) the Stripe Checkout page. Gives us a clean,
// owned https return URL for iOS/Android without standing up separate hosting.
// The customer taps "Done" to dismiss the browser and return to the app, where
// the order (created server-side by the stripe-webhook) is already waiting.
//
// The WEB app does NOT use this — it redirects back to its own origin instead.
// verify_jwt MUST be false (this is a top-level browser navigation from Stripe).

Deno.serve((req: Request) => {
  const url = new URL(req.url)
  const status = url.searchParams.get('status') ?? 'success'
  const success = status !== 'cancel'

  // NOTE: paying here only places an authorization HOLD (capture_method=manual).
  // The card is NOT charged until a provider STARTS the job, so this copy must not
  // say "payment received"/"charged" — that would contradict the hold promise.
  const title = success ? "You're all set" : 'Order canceled'
  const emoji = success ? '❄️' : '↩️'
  const message = success
    ? "Your order is in — head back to the SnowServ app and we'll find a provider " +
      "near you. Your card is only charged once a provider starts the job."
    : 'No charge was made. Return to the SnowServ app to try again.'

  const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${title}</title>
  <style>
    :root { color-scheme: light dark; }
    body {
      margin: 0; min-height: 100vh; display: flex; align-items: center;
      justify-content: center; font-family: -apple-system, BlinkMacSystemFont,
      'Segoe UI', Roboto, sans-serif; background: #F0F6FF; color: #0B2447;
    }
    .card {
      text-align: center; padding: 40px 28px; max-width: 340px;
    }
    .emoji { font-size: 56px; }
    h1 { font-size: 22px; margin: 16px 0 8px; }
    p { font-size: 15px; line-height: 1.5; color: #33507a; margin: 0 0 24px; }
    button {
      background: #0B2447; color: #fff; border: 0; border-radius: 12px;
      padding: 14px 28px; font-size: 16px; font-weight: 600; cursor: pointer;
    }
    @media (prefers-color-scheme: dark) {
      body { background: #0B2447; color: #F0F6FF; }
      p { color: #b9c8e0; }
      button { background: #4A90E2; }
    }
  </style>
</head>
<body>
  <div class="card">
    <div class="emoji">${emoji}</div>
    <h1>${title}</h1>
    <p>${message}</p>
    <button onclick="window.close()">Done</button>
  </div>
</body>
</html>`

  return new Response(html, {
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
  })
})
