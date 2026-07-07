# SnowServ App

## What this app is
Uber-style snow removal marketplace. Customers request snow removal services, providers accept jobs. Built with Flutter + Supabase.

## Supabase project
- URL: https://swttuujhcgpcsrxgupzv.supabase.co
- Anon key: sb_publishable_SnyCvdfwgHOQe-NB0D8Ipw_DUI9uWRe
- Service role key: (stored in Supabase dashboard — do not commit)

## Database tables

### jobs
id, customer_id (fkey → users), provider_id (fkey → providers), address_id (fkey → addresses), job_type, provider_type_required, driveway (bool), walkway (bool), salting (bool), base_price, surge_multiplier, final_price, status, payment_intent_id (text), created_at, completion_photos (text[]), provider_notes (text), service_type, snow_level, customer_rating (int), dispatched_to (fkey → providers), dispatched_at, rejected_providers (text[]), job_lat, job_lng

Valid status values: requested, assigned, in_progress, completed, cancelled
NOT valid: pending, accepted (violate jobs_status_check constraint)

SECURITY: provider_notes must NEVER be shown to customers — admin panel only.

### users (public)
id (uuid, matches auth.users.id), name, email, phone, role, dispute_count, is_flagged, is_suspended, created_at, stripe_customer_id, card_pm_id, card_last4, card_brand, card_exp_month, card_exp_year

### providers
id (uuid, auto-generated — NOT same as auth user id), user_id (fkey → users), provider_type, is_online, is_verified, registration_status (approved/pending/rejected), current_lat, current_lng, has_vehicle, crew_size, rating, total_jobs, created_at

IMPORTANT: jobs.provider_id references providers.id (NOT auth user id). Must look up providers.id via user_id when accepting jobs.
IMPORTANT: When querying jobs with provider join, use `providers!jobs_provider_id_fkey` to avoid ambiguous FK error.

### profiles
id (uuid, matches auth.users.id), role (customer/provider), full_name, phone, is_online, created_at
Used for: role-based routing in Flutter (RoleRouter)

### addresses
id, user_id, address_line, city, state, zip

### service_areas
id, name, zips (text[], legacy), polygon (jsonb — ordered list of {lat,lng} vertices),
price_sidewalk, price_driveway, price_both, price_salting, is_active (bool), created_at.
Drives REGIONAL pricing + who can order via GEOFENCED ZONES: the customer's address is
geocoded to a lat/lng point, then tested (point-in-polygon, client-side in Dart —
lib/utils/geo.dart matchZone) against each active zone's `polygon`; the matching zone's
prices apply. No matching zone → can't order ("Not available in your area yet"). Managed
in the admin panel's "Areas" tab via a map-based polygon drawer (lib/screens/admin/
zone_editor_screen.dart). `zips` is a LEGACY fallback: matchZone falls back to zips @> [zip]
only for zones that have no polygon yet (migration safety) or when geocoding failed.
Public SELECT via RLS (so the pre-signup quote can read zones with the anon key).
REQUIRES: `ALTER TABLE service_areas ADD COLUMN IF NOT EXISTS polygon jsonb;`

### waitlist
id, email, zip, address, created_at. Captured when someone's ZIP isn't served yet
(from the order screen banner or the pre-signup quote screen).

### payments
Schema unknown.

## Auth flow
- Email confirmation is ON — users must confirm email before logging in
- On signup: insert into profiles, users, and providers (if role=provider)
- No trigger — profile/user/provider creation handled in Flutter (auth_screen.dart)
- Role stored in profiles.role — used to route to CustomerHome or ProviderHome

## File structure
```
lib/
  main.dart                             — app entry, AuthGate, RoleRouter
  screens/
    quote_screen.dart                   — pre-signup instant quote by address ZIP + waitlist
    auth/
      auth_screen.dart                  — login, signup, forgot password
    customer/
      customer_home.dart                — service selector, request job, active jobs, payment
      job_history_screen.dart           — My Orders screen with receipts (completed jobs)
      address_screen.dart               — add/edit saved address
    provider/
      provider_home.dart                — online toggle, available jobs, active jobs, cancel
      job_history_screen.dart           — provider job history
    admin/
      admin_screen.dart                 — jobs, payouts, user flags, service Areas tab
```

## Pricing
- REGIONAL: prices come from the matched service_areas zone (geofenced polygon that
  the geocoded address falls inside), editable in the admin "Areas" tab — NOT hardcoded.
  Values below are the Yonkers launch defaults.
- Sidewalk only: $50
- Driveway only: $100
- Sidewalk + Driveway: $125
- Salting add-on: +$40
- Storm pricing (labeled "Storm pricing" in customer UI; internal var still surge_multiplier):
  base_price × multiplier (live — driven by snow depth via Open-Meteo API)
  - 0–3": 1.0x, 3–6": 1.3x, 6–10": 1.7x, 10"+: 2.3x
- Platform commission: 30% (admin panel), provider payout: 70%
- Payouts: 7-day rolling batch via admin panel

## Payment flow (Stripe Checkout)
- Migrated OFF flutter_stripe → **Stripe Checkout** (hosted page) 2026-07-07 so ONE
  code path serves iOS, Android AND web (Mac/Windows use the web app in a browser).
  flutter_stripe was mobile-only and broke `flutter build web`; Checkout also brings
  Apple Pay / Google Pay for free on its page. NO client-side Stripe SDK anymore.
- iOS still uses Swift Package Manager only — CocoaPods fully deintegrated.
- Flow (lib/screens/customer/customer_home.dart `createJob`):
  1. Client calls `create-checkout-session` with amount + ALL job fields in `metadata`
     + platform return URLs → gets a hosted Checkout `url`.
  2. Client opens it: web = same-tab redirect (`launchUrl(webOnlyWindowName:'_self')`);
     mobile = in-app browser (`LaunchMode.inAppBrowserView`). No job inserted here.
  3. Customer pays on Stripe's page → authorizes the HOLD (capture_method: manual).
  4. `stripe-webhook` (checkout.session.completed) is the SOURCE OF TRUTH: inserts the
     address (for "someone else" orders) + job (status=requested) with
     payment_intent_id = session.payment_intent, mirrors card→users, calls the
     `dispatch_jobs()` RPC. Robust across the web redirect / a closed tab.
  5. Job shows in-app via Realtime (`subscribeToJobs`) / loadMyJobs.
- Return URLs: web → app origin `?checkout=success|cancel` (app reloads → snackbar via
  `_handleWebCheckoutReturn`); mobile → the `checkout-return` edge fn HTML page.
- Saved cards: Checkout manages them (pass the Stripe customer; setup_future_usage=
  off_session). users.card_* is now just a "card on file" chip, filled by the webhook.
  `get-payment-methods` + `create-payment-intent` are now UNUSED (kept as fallback).
- Stripe customer ID stored in users.stripe_customer_id.
- Stripe publishable key: pk_test_51TlZBgBYwOCAVVcUcMmYaVCyiv7YF8unZA7afdyHkAFauYaxiLVwU8Z4fhWScwRgm7cAmC5H6kGYfHT03tRuyvbX00MR63QKKG
- Stripe secret key: stored as Supabase secret STRIPE_SECRET_KEY — never commit.
- Stripe webhook signing secret: STRIPE_WEBHOOK_SECRET (Supabase secret, never commit).
  ✅ CONFIGURED 2026-07-07 (test mode): endpoint registered in the Stripe sandbox
  (event checkout.session.completed), secret set, verified end-to-end (pay → webhook →
  job created → dispatch → capture on provider Start; cancel releases the hold).
  ⚠️ When going LIVE: add a SECOND endpoint in Live mode and set its different whsec_.

## Edge functions (supabase/functions/)
- create-checkout-session: creates a Stripe Checkout Session (capture_method manual =
  HOLD), embeds all job fields in metadata, returns the hosted-page `url`. Has CORS
  (called from the web app). Replaced create-payment-intent.
- stripe-webhook: verify_jwt=false; verifies the Stripe signature, and on
  checkout.session.completed idempotently creates the address+job with the held PI,
  mirrors the card onto users, and calls dispatch_jobs(). Needs STRIPE_WEBHOOK_SECRET.
- checkout-return: verify_jwt=false; tiny HTML success/cancel page for the mobile
  in-app browser to land on after Checkout (owned https return URL, no extra hosting).
- create-payment-intent: LEGACY/unused (flutter_stripe era) — kept, safe to delete.
- get-payment-methods: LEGACY/unused (Checkout shows saved cards itself) — kept.
- refund-job: looks up payment_intent_id on job, issues full Stripe refund
- notify-providers: notifies providers of new job
- notify-provider: notifies single provider (e.g. cancellation)
- notify-customer: notifies customer (e.g. provider cancelled)
- capture-payment: captures the held PaymentIntent when a provider STARTS the job
  (markInProgress → status in_progress); idempotent. NOT on accept.
- notify-dispatch: notifies only the single provider a job was dispatched to
- admin-doc-url: verifies admin password (ADMIN_PASSWORD secret) → returns a 1h
  signed URL for a provider-documents file (service role). Only way to read that
  private bucket.

## Storage buckets
- job-photos: PUBLIC (completion photos shown to customers). Read via getPublicUrl.
- provider-documents: PRIVATE. Registration stores the object PATH (not a URL) in
  providers.dl_photo_url / insurance_photo_url. Admin views via the admin-doc-url
  function (password-gated signed URLs) — customers/providers/public cannot read it.
## Admin access
- Admin is identified by profiles.is_admin (boolean). No shared password anymore.
- An "Admin Panel" entry shows in the account menu (customer + provider home) only
  for is_admin users → opens AdminPanelScreen directly.
- admin-doc-url (and future admin-only server actions) verify the caller's login
  token maps to an is_admin profile. To grant admin: set profiles.is_admin=true.
- NOT yet done: locking down RLS so the DB enforces admin-only writes broadly
  (see PRELAUNCH.md — full RLS lockdown is a dedicated pre-launch task).

## Provider flow
1. Toggle online → loads available jobs (status=requested, dispatched_to=this provider)
2. Accept job → status becomes assigned, job moves to Active Jobs section
3. Start Job → status becomes in_progress
4. Complete job → status becomes completed (photos + notes optional)
5. Reject job → provider added to rejected_providers, job re-dispatched to next nearest
6. Cancel accepted job → confirmation dialog, job reset to requested, re-dispatched, customer notified
7. Cancel AFTER start (post-capture — decided 2026-07-07): the charge STAYS and the job
   re-dispatches already paid (capture-payment is idempotent, so the next provider's
   Start never double-charges). Customer gets an honest push (notify-customer status
   'provider_cancelled_after_start': "no extra charge / won't be charged again / cancel
   for a full refund" — cancel is available again since status is back to requested,
   and refund-job sees the captured PI → full refund). Each post-start cancel increments
   providers.cancelled_after_start_count (RPC increment_post_start_cancel, self-only)
   and shows as a red warning on the admin panel's provider cards.

## Dispatch (how jobs are routed)
- Two dispatchers, kept in sync: the client `dispatchToNearest` (lib/utils/dispatch.dart,
  runs at order time / on decline) and a pg_cron `dispatch_jobs()` running every minute
  (supabase/migrations/*dispatch* — the always-on workhorse that expires stale offers
  and dispatches queued jobs regardless of any app being open).
- LOAD-AWARE ranking (both paths): fewest active jobs first, then proximity — no hard
  cap, so nothing is stranded when everyone is busy.
- PREFERRED-DRIVER OVERRIDE (providers.preferred_until timestamptz, admin-panel toggle
  on the provider card): the admin's "take care of a certain driver" lever. RELATIVE
  rule (not a fixed radius, not an unconditional bump): while the override is live, the
  preferred driver wins a new job ONLY when they're EQUAL-OR-CLOSER to it than the
  driver who'd otherwise be picked — so they're never sent a worse-distance job; the
  override just lets them win the close calls (incl. beating a less-busy-but-farther
  driver). AUTO-EXPIRES at preferred_until (admin picks 4h/8h/24h; no cron). Both
  dispatchers implement it identically: dispatch_jobs() picks the normal winner + the
  nearest live-preferred driver and swaps only if pref_dist <= normal_dist; the client
  dispatchToNearest mirrors this. Admin card shows a gold "Preferred · Nh left" badge.
- AUTO-ACCEPT (providers.auto_accept, opt-in toggle on provider home): a job routed to
  an auto-accept provider is assigned directly (status=assigned) instead of a pending
  offer — no countdown to miss. Provider notified via notify-provider status
  'auto_assigned' from BOTH paths: the client calls it directly; the cron calls it
  via pg_net (net.http_post, same pattern as the payout cron) so a closed-app
  provider still gets the push.
- NOTE: cron expires offers at 3 min but the provider UI countdown is 4 min
  (_kDispatchSeconds=240) — a known minor mismatch, not yet reconciled.

## Provider Service Agreement (anti-harvesting)
- Provider-specific contract with a Non-Circumvention / Non-Solicitation clause
  (no taking SnowServ customers off-platform). Source text: docs/provider_service_agreement.md
  (a founder draft — NEEDS a NY attorney review; still has a [Company Legal Name] placeholder).
- Rendered in-app: lib/screens/provider/provider_agreement_screen.dart (exports
  kProviderAgreementVersion). Linked from the provider account menu too.
- Signed at REGISTRATION only (existing/approved providers are NOT gated — decided
  2026-07-06): agreement page has a read-link + typed full-name e-signature + required
  checkbox; can't submit until signed. Stored on providers:
  service_agreement_signed_at, service_agreement_name, service_agreement_version.

## Customer flow
1. Add address (required before ordering)
2. Select service + salting option
3. Pay via Stripe (saved card or new card entry)
4. Home screen shows active jobs only (requested/assigned/in_progress)
5. Cancel job → Stripe refund issued automatically, provider notified
6. "My Orders" button → job history screen with receipts for completed jobs
7. Rate completed jobs (1–5 stars) from orders screen

## Ordering for someone else
Customer can toggle "Ordering for someone else" to enter a different service address for that order only. A new address record is inserted for that job.

## What's working
- Customer signup/login/logout
- Provider signup/login/logout
- Customer requests job (service selector + pricing + surge)
- Stripe payment with saved card support
- Provider goes online/offline
- Provider sees available jobs (dispatched to them), accepts or rejects
- Active jobs shown to provider after accepting
- Provider can cancel accepted job — job re-enters queue
- Customer can cancel job — full Stripe refund issued automatically
- Job dispatch to nearest online approved provider
- Customer job history + receipts ("My Orders")
- Provider job history
- Admin panel (job management, payouts, user flags)
- Forgot password flow
- Real-time job updates via Supabase Realtime (requires Realtime enabled on jobs table in Supabase dashboard)

## What's NOT built yet
- Apple Pay as a dedicated integration — NOTE: Stripe Checkout now surfaces Apple Pay
  / Google Pay automatically on its hosted page where the device/browser supports it
  (web Apple Pay needs a one-time Stripe domain registration). So the wallet buttons
  largely come "for free" with the Checkout migration.

## Deliberately NOT doing (decided, do not re-propose)
- Modifying an order after it's placed (e.g. "add salting" later). Considered and
  rejected 2026-07-05: too confusing and not worth the payment-flow complexity
  (the hold can't be raised, so it needs a new hold / delta charge). If a customer
  forgets an add-on, they cancel and re-book — the instant hold-release makes that
  painless. Order-time selection is the only place to choose services + salting.

## Recently built (previously on the NOT-built list)
- Job completion UI (provider marks done, uploads photos to job-photos bucket)
- Push notifications (FCM/APNs) for dispatch, accept, cancel, completion
- App icon (flutter_launcher_icons) + native splash screen (flutter_native_splash,
  iOS + Android): navy snowflake icon centered on frost #F0F6FF
- Android platform scaffolding exists (android/ dir tracked)

## Payment model (authorize-and-capture)
- Order places an authorization HOLD via Stripe Checkout
  (create-checkout-session sets payment_intent_data[capture_method]=manual). The
  Checkout Session still yields a normal PaymentIntent in requires_capture, so the
  hold model is unchanged from the old flutter_stripe flow — capture-payment and
  refund-job operate on jobs.payment_intent_id exactly as before.
- Provider STARTING the job captures the hold (capture-payment, idempotent), called
  from markInProgress (status → in_progress). Accept does NOT capture — it stays a
  hold through requested/assigned. Chosen 2026-07-06 so a customer who cancels before
  work begins is never charged (customers can only cancel before In Progress anyway).
  The order screen shows a "this is a hold, not a charge" note; FAQ matches.
- Cancel before start RELEASES the hold instantly (refund-job cancels the PI);
  cancel after capture issues a real refund. refund-job returns action:
  released|refunded so the customer sees the right message.

## Secrets & keys (verified 2026-07-05)
Public-by-design, correctly in client code (lib/main.dart): Stripe publishable
key (pk_test), Supabase anon/publishable key. Firebase API key (AIza…) in
ios/Runner/GoogleService-Info.plist is Firebase client config, not secret.
Server-side only (Supabase env vars, never in repo): STRIPE_SECRET_KEY,
SUPABASE_SERVICE_ROLE_KEY, FIREBASE_SERVICE_ACCOUNT (Admin private key).
`*firebase-adminsdk*.json` is gitignored.

Hardening applied 2026-07-05: the Firebase "iOS key (auto created by Firebase)"
(ends …NZz7Nk) is restricted in Google Cloud Console (project snowserv-a5a29) to
Application restriction = iOS apps, bundle ID com.snowserv.app. API restrictions
left unrestricted on purpose — restricting them risks breaking FCM push. The
Browser key and firebase-adminsdk service account were left untouched.

## Domain & support email
snowserv.app registered at Cloudflare (registrar + DNS). support@snowserv.app is a live
Zoho Mail (free plan) alias on mailbox snowserv.app@snowserv.app; MX/SPF/DKIM set in
Cloudflare DNS. The app's "Contact Support" links point to support@snowserv.app.

## SQL to run (if not done yet)
```sql
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS payment_intent_id text;
-- Geofenced pricing zones (polygon boundary per service_areas row):
ALTER TABLE service_areas ADD COLUMN IF NOT EXISTS polygon jsonb;
```
After running the polygon migration, open each existing zone in the admin "Areas" tab
and draw its boundary (tap the map) → Save. Until a zone has a polygon, ordering in it
falls back to its legacy `zips` list.

## macOS entitlements
Both network.client and network.server enabled in macos/Runner/DebugProfile.entitlements

## iOS
- Minimum deployment target: iOS 14+
- Swift Package Manager only (CocoaPods fully removed)
- flutter_stripe REMOVED 2026-07-07 (payments now via Stripe Checkout hosted page —
  see "Payment flow"). No native Stripe SDK, so the old "flutter_stripe v13 for iOS 26"
  constraint no longer applies.
