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
id, name, zips (text[]), price_sidewalk, price_driveway, price_both, price_salting,
is_active (bool), created_at. Drives REGIONAL pricing + who can order: a customer's
address ZIP is matched to an active area (zips @> [zip]); that area's prices apply.
No active area for the ZIP → can't order ("Not available in your area yet"). Managed
in the admin panel's "Areas" tab. Public SELECT via RLS (so the pre-signup quote can
read prices with the anon key).

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
- REGIONAL: prices come from the matched service_areas row (per ZIP), editable in
  the admin "Areas" tab — NOT hardcoded. Values below are the Yonkers launch defaults.
- Sidewalk only: $50
- Driveway only: $100
- Sidewalk + Driveway: $125
- Salting add-on: +$40
- Storm pricing (labeled "Storm pricing" in customer UI; internal var still surge_multiplier):
  base_price × multiplier (live — driven by snow depth via Open-Meteo API)
  - 0–3": 1.0x, 3–6": 1.3x, 6–10": 1.7x, 10"+: 2.3x
- Platform commission: 30% (admin panel), provider payout: 70%
- Payouts: 7-day rolling batch via admin panel

## Payment flow (Stripe)
- flutter_stripe v13 (required for iOS 26 compatibility)
- iOS uses Swift Package Manager only — CocoaPods fully deintegrated
- Flow: createPaymentMethod → confirmPayment → store payment_intent_id on job
- Saved card: stored in users table (card_pm_id, card_last4, card_brand, card_exp_month, card_exp_year)
- Stripe customer ID stored in users.stripe_customer_id
- Stripe publishable key: pk_test_51TlZBgBYwOCAVVcUcMmYaVCyiv7YF8unZA7afdyHkAFauYaxiLVwU8Z4fhWScwRgm7cAmC5H6kGYfHT03tRuyvbX00MR63QKKG
- Stripe secret key: stored as Supabase secret STRIPE_SECRET_KEY — never commit

## Edge functions (supabase/functions/)
- create-payment-intent: creates Stripe PaymentIntent, returns client_secret + payment_intent_id
- refund-job: looks up payment_intent_id on job, issues full Stripe refund
- notify-providers: notifies providers of new job
- notify-provider: notifies single provider (e.g. cancellation)
- notify-customer: notifies customer (e.g. provider cancelled)
- capture-payment: captures the held PaymentIntent when a provider accepts (idempotent)
- notify-dispatch: notifies only the single provider a job was dispatched to
- admin-doc-url: verifies admin password (ADMIN_PASSWORD secret) → returns a 1h
  signed URL for a provider-documents file (service role). Only way to read that
  private bucket.

## Storage buckets
- job-photos: PUBLIC (completion photos shown to customers). Read via getPublicUrl.
- provider-documents: PRIVATE. Registration stores the object PATH (not a URL) in
  providers.dl_photo_url / insurance_photo_url. Admin views via the admin-doc-url
  function (password-gated signed URLs) — customers/providers/public cannot read it.
- Admin panel auth is still the client-side password (admin_screen _adminPassword),
  now also server-verified for doc access. Real admin auth = separate hardening item.

## Provider flow
1. Toggle online → loads available jobs (status=requested, dispatched_to=this provider)
2. Accept job → status becomes assigned, job moves to Active Jobs section
3. Start Job → status becomes in_progress
4. Complete job → status becomes completed (photos + notes optional)
5. Reject job → provider added to rejected_providers, job re-dispatched to next nearest
6. Cancel accepted job → confirmation dialog, job reset to requested, re-dispatched, customer notified

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
- Apple Pay

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
- Order places an authorization HOLD (create-payment-intent: capture_method manual)
- Provider accept captures the hold (capture-payment edge fn, idempotent)
- Cancel before accept RELEASES the hold instantly (refund-job cancels the PI);
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
```

## macOS entitlements
Both network.client and network.server enabled in macos/Runner/DebugProfile.entitlements

## iOS
- Minimum deployment target: iOS 14+
- Swift Package Manager only (CocoaPods fully removed)
- flutter_stripe v13 required for iOS 26
