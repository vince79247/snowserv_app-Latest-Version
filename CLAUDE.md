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
      admin_screen.dart                 — job management, payouts, user flags
```

## Pricing
- Sidewalk only: $50
- Driveway only: $100
- Sidewalk + Driveway: $125
- Salting add-on: +$40
- Surge pricing: base_price × surge_multiplier (live — driven by snow depth via Open-Meteo API)
  - 0–8": 1.0x, 8–13": 1.25x, 13–18": 1.5x, 18"+: 2.0x
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
- Job completion UI (provider marks done, uploads photos)
- Push notifications
- Apple Pay
- Android configuration
- App icon and splash screen
- Customer in-app job modification after provider accepts (e.g. add salting)

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
