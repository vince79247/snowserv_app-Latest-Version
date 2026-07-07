# SnowServ — Pre-launch / Hardening Checklist

Living list of what must happen before real users, in rough priority order.
Status: ✅ done · 🔨 in progress · ⏳ todo · 🧊 later. "Needs you" = requires
Vince (Apple portal, decisions, etc.), not just code.

## 🚦 Go-live blockers (ordered) — the checklist to a public launch
These gate taking REAL money from REAL users on ANY platform (iOS *or* web) — none can
be safely retrofitted once live. Pure features/UX are NOT here; ship those via updates
anytime. (Added 2026-07-07.)
1. **Business + legal** (you + CPA/attorney) — form the LLC + EIN and settle sales-tax
   handling. Gates real revenue. See ROADMAP.md → Payments, tax & legal.
2. **Live Stripe** — swap test keys (pk_test/sk_test) for LIVE keys under the entity's
   Stripe account. Test mode = no real charges.
3. **RLS lockdown** — tighten row-level security so the DB enforces access before real
   users hit the API (see Security hardening below). The heavyweight.
4. **App Store essentials** (iOS only) — privacy-policy URL in App Store Connect,
   metadata + screenshots, and test on a REAL iPhone (not just simulators).

NOT launch blockers — do before you SCALE, not before the first pilot:
- Stripe Connect + Sales Tax epic (design now; a small controlled pilot can run on the
  current manual-payout model — but don't scale without Connect).
- Load test (k6/Artillery) — traffic is tiny at first; matters before multi-town/storm scale.

Low-risk momentum any time: a TestFlight build on your own iPhone, and a marketing
website / pre-signup quote page — the latter needs NONE of the above (no payments).

## Handoff — where we left off (2026-07-07 session)
The Stripe-Checkout payments migration below is DONE IN THE WORKING TREE but NOT yet
committed/pushed (commit when ready) — everything ABOVE it was already committed +
pushed to GitHub branch `geofenced-pricing-zones` (not merged to main). Git auth is the
IDE's GitHub OAuth login (leaked PAT deleted). Supabase project is CLI-linked — Claude
can run migrations (`supabase db push`) and deploy edge functions.

**⚠️ Checkout is NOT live end-to-end until you do this ONE Stripe step:** in the Stripe
Dashboard → Developers → Webhooks, add an endpoint
`https://swttuujhcgpcsrxgupzv.supabase.co/functions/v1/stripe-webhook` subscribed to
`checkout.session.completed`, then set its signing secret:
`supabase secrets set STRIPE_WEBHOOK_SECRET=whsec_...`. Until then the webhook returns
400 and paying on Checkout won't create a job. (STRIPE_SECRET_KEY already set.)

**Shipped the Stripe Checkout migration (working tree, verified — `flutter build web`
now succeeds, which flutter_stripe used to break):**
- NEW edge fns (deployed): create-checkout-session (Session, capture_method=manual =
  the HOLD, job fields in metadata, CORS for web), stripe-webhook (verify_jwt=false;
  Stripe-signature check; idempotent address+job insert with the held PI; mirrors card
  →users; calls dispatch_jobs() RPC), checkout-return (verify_jwt=false; HTML return
  page for the mobile in-app browser). config.toml updated for the two verify_jwt=false.
- Client (customer_home.dart): createJob now opens hosted Checkout (web = same-tab
  redirect; mobile = in-app browser) instead of the in-app card sheet; deleted
  `_PaymentSheet`/CardField; job insert + dispatch moved server-side (webhook). Kept the
  "hold, not a charge" note + a "card on file" chip on the order screen; web return
  handled by `_handleWebCheckoutReturn` (`?checkout=success|cancel`).
- Removed flutter_stripe from pubspec + main.dart. Also had to bump transitive
  `cross_file` (an image_picker dep) — its old pin used `UnmodifiableUint8ListView`,
  removed in current Dart, and was the NEXT thing breaking `flutter build web`.
- capture-payment + refund-job carried over UNCHANGED (still key off payment_intent_id).
  create-payment-intent + get-payment-methods are now unused legacy (kept, safe to del).

**Shipped the PRIOR session (all committed + verified on the iOS sims unless noted):**
- Geofenced pricing zones — ZIP matching → drawn polygons. Admin map drawer
  (zone_editor_screen.dart, flutter_map), matchZone in lib/utils/geo.dart, Yonkers
  polygon drawn. `zips` kept as legacy fallback.
- Admin tab contrast; one-active-order-per-address duplicate-order guard.
- Payment: capture moved provider Accept → provider START (markInProgress); "this is
  a hold, not a charge" note on the payment sheet; FAQ aligned.
- Provider dashboard reliability: iOS foreground push presentation + resume/onMessage
  refresh + markInProgress stale-job guard (both push bugs fixed).
- Provider Service Agreement (anti-harvesting/non-circumvention) — in-app screen +
  registration typed-signature + migration. DRAFT: needs NY attorney review + fill
  [Company Legal Name].
- App display name → "SnowServ" (iOS + Android).
- Load-aware dispatch (client dispatchToNearest AND the pg_cron dispatch_jobs) +
  queue-position display ("N jobs ahead") replacing the broken minute-ETA.
- Auto-accept toggle (providers.auto_accept; assigns in both dispatch paths; cron
  pushes via pg_net) + Directions button on the active-job card.
- Trust messaging: "No contracts / no monthly / no hidden fees" (customer + provider).
- DB indexes on hot job/provider paths; GitHub-token leak closed.

**✅ Stripe Checkout migration — DONE (see the shipped block above).** Was the mobile-
only flutter_stripe blocking `flutter build web`; now one hosted-Checkout path for iOS,
Android + web, hold model preserved. Remaining to make it live end-to-end: the ONE
Stripe webhook step at the top of this Handoff (endpoint + STRIPE_WEBHOOK_SECRET).

**➡️ NEXT TASK options (pick with Vince):**
1. **Wire up + test Checkout end-to-end** — do the Stripe webhook step, then a full
   test-mode order on each of iOS sim, web (`flutter run -d chrome`), and Android:
   pay → confirm the webhook creates the job → provider START captures the hold →
   cancel-before-start releases it. Verify saved-card reuse + the "card on file" chip,
   and Apple/Google Pay showing on the hosted page. Also register the web domain for
   Apple Pay in Stripe if we want the Apple Pay button on web.
2. **Stripe Connect + Sales Tax epic** (ROADMAP) — the Checkout migration was designed
   as the front half of this. Platform is tax collector of record; design together.
3. **Web app polish** — now that `flutter build web` works, the Flutter web app is
   unblocked (real admin auth + a hosting/deploy target still needed).

**Other open threads:** marketing website (separate, SEO-friendly, NOT Flutter web);
founder critical path = LLC + EIN + CPA/sales-tax (gates real money). See "Go-live
blockers" above.

## Security hardening
- ✅ Firebase iOS API key restricted to bundle id (Google Cloud Console)
- ✅ Provider documents: private bucket + admin-only signed-URL viewing (admin-doc-url)
- ✅ Secrets server-side only (Stripe secret, service role, Firebase admin)
- 🔨 **Real admin authentication** — replace the shared client-side admin password
  with a real `profiles.is_admin` account; verify server-side in functions.
- ✅ **GitHub token in git remote** — removed the leaked classic PAT from the origin URL
  AND deleted it on GitHub (was "SnowServ2": repo scope, no expiration). Git already
  authenticates via the IDE's GitHub OAuth login (gho_ token in the macOS Keychain), so
  no PAT is in the URL or needed. Leak closed 2026-07-07.
- 🧊 **Full RLS lockdown** — the app currently runs on permissive/loose row-level
  security. Tightening every table's policies so the DB enforces who-can-do-what
  is the big one: touches every flow (order, accept, payout, admin) and needs
  full re-testing. **Dedicated session right before launch — do not rush mid-build.**
  - CAVEAT: the customer "N jobs ahead of you" line (customer_home
    `_refreshQueuePositions`) counts the assigned provider's OTHER active job
    rows — it works today only because SELECT on jobs is permissive. When
    locking down, preserve a path for that count (a narrow policy, an RPC, or an
    edge function) or the queue-position display silently reads 0/blank. Same
    applies to any anon jobs reads used for diagnostics.

## Auth / signup (conversion)
- ⏳ **Provider Service Agreement** (built 2026-07-06, anti-harvesting/non-circumvention):
  (1) have a NY attorney review docs/provider_service_agreement.md before launch;
  (2) fill the `[Company Legal Name]` placeholder (doc + provider_agreement_screen.dart);
  (3) manual test — run a full NEW provider registration and confirm the read-link +
  typed-signature + checkbox block submit until signed, and the signature saves to
  providers.service_agreement_* . Existing providers are NOT gated (decided new-only).
- ⏳ **Sign in with Apple** (+ optional Google). NOTE: Apple Guideline 4.8 — offering
  *any* social login forces Sign in with Apple too. Needs: Apple portal config
  (needs you), first-login provisioning of profiles/users/providers rows, and a
  "customer or provider?" step after social sign-in.

## Scale / reliability
- ⏳ **Paid geocoder** — pricing/availability now geocodes the address (quote + order)
  to match it to a geofenced zone. Currently uses free OSM Nominatim (rate-limited
  ~1 req/s, not meant for commercial volume; debounced + result reused). Swap for
  Google/Mapbox before real volume. Shared helper: lib/utils/geocode.dart.
- ⏳ **Storm-burst load test** — simulate a spike (k6 / Artillery) on order→dispatch;
  the real risk for this app is bursts during storms, not steady traffic. Do before launch.
- ⏳ **Multi-provider dispatch + queue-position functional test** (deferred from
  build 2026-07-06, low-risk sort/display change): with 2–3 online approved
  providers and stacked jobs, confirm load-aware dispatch routes new jobs to the
  least-busy nearby provider, and the customer's "N jobs ahead of you" line
  counts correctly. Natural to fold into a pre-launch beta/dry-run.
- ⏳ **Database indexes** on hot paths: jobs(customer_id), jobs(status),
  jobs(dispatched_to), providers(user_id), service_areas(zips GIN).
- ⏳ **Supabase Pro plan** + watch metrics dashboard (CPU, connections, slow queries).
  Launch scale (one town) is tiny — scale the plan up as usage grows.

## Ops / admin
- ⏳ **Web admin** — `flutter build web` reuses the existing admin screen in a laptop
  browser (lowest effort). Prerequisite: real admin auth (a browser URL is exposed).
  Later option: purpose-built dashboard or a low-code tool (Retool) on Supabase.

## App Store submission (needs you)
- ⏳ Paste Privacy Policy URL into App Store Connect (privacy policy field)
- ✅ Domain owned: snowserv.app (Cloudflare) + support@snowserv.app (Zoho) live
- ⏳ **Android setup** (only if launching Android): google-services.json,
  applicationId com.snowserv.app (change from com.example — can't change after first
  upload), release signing keystore (back it up!), Android launcher icon, google-services plugin.

## Done recently (for reference)
- ✅ Authorize-and-capture payments (deployed); all edge functions deployed & current
- ✅ service_areas regional pricing + availability gate + pre-signup quote
- ✅ Storm pricing scale + rename
- ✅ Legal links in-app + sign-up consent
