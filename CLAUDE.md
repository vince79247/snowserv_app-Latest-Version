# SnowServ App

## What this app is
Uber-style snow removal marketplace. Customers request snow removal services, providers accept jobs. Built with Flutter + Supabase.

## Supabase project
- URL: https://swttuujhcgpcsrxgupzv.supabase.co
- Anon key: sb_publishable_SnyCvdfwgHOQe-NB0D8Ipw_DUI9uWRe
- Service role key: (stored in Supabase dashboard — do not commit)

## Database tables

### jobs
id, customer_id (fkey → users), provider_id (fkey → providers), address_id (fkey → addresses), job_type, provider_type_required, driveway (bool), walkway (bool), salting (bool), base_price, surge_multiplier, final_price, status, payment_intent_id (text), created_at, completion_photos (text[]), provider_notes (text), service_type, snow_level, customer_rating (int), dispatched_to (fkey → providers), dispatched_at, rejected_providers (text[]), job_lat, job_lng, start_distance_m, complete_distance_m (on-site verification, meters), before_photos (text[] — optional "before" shots from Start)

Valid status values: requested, assigned, in_progress, completed, cancelled
NOT valid: pending, accepted (violate jobs_status_check constraint)

SECURITY: provider_notes must NEVER be shown to customers — admin panel only.

### users (public)
id (uuid, matches auth.users.id), name, email, phone, role, dispute_count, is_flagged, is_suspended, created_at, stripe_customer_id, card_pm_id, card_last4, card_brand, card_exp_month, card_exp_year

### providers
id (uuid, auto-generated — NOT same as auth user id), user_id (fkey → users), provider_type, is_online, is_verified, registration_status, current_lat, current_lng, has_vehicle, crew_size, rating, total_jobs, created_at, equipment (shovel/snowblower/plow), id_type, dl_number, dl_state, dl_photo_url, insurance_*, review_note, reviewed_at, recruit_emailed_at, stripe_connect_id, payouts_enabled, auto_accept, preferred_until, cancelled_after_start_count, provider_number

registration_status values: incomplete · pending_review · approved · rejected · deleted

NO IDENTITY DOCUMENTS ARE COLLECTED (2026-08-07). dl_number / dl_state /
dl_photo_url / id_type are DEPRECATED, nulled, and their storage objects purged.
Stripe Connect Express verifies identity during payout onboarding — legal name,
DOB, address, SSN, checked against government records — and asks for a photo ID
itself if its automated check fails. Our copy bought an admin squinting at a photo
while making us hold NY SHIELD Act "private information". The verified identity is
readable any time from GET /v1/accounts/{id} or the Stripe Dashboard → Connected
accounts; only the full SSN and any ID scan stay with Stripe. Columns are kept (not
dropped) ONLY because build 16 still writes them — drop once 17+ is the floor.

IMPORTANT: jobs.provider_id references providers.id (NOT auth user id). Must look up providers.id via user_id when accepting jobs.
IMPORTANT: When querying jobs with provider join, use `providers!jobs_provider_id_fkey` to avoid ambiguous FK error.

### profiles
id (uuid, matches auth.users.id), role (customer/provider), full_name, phone, is_online, created_at
Used for: role-based routing in Flutter (RoleRouter)

### addresses
id, user_id, address_line, city, state, zip, price_multiplier (numeric default 1.0 —
per-address custom pricing; see Pricing section)

### service_areas
id, name, zips (text[], legacy), polygon (jsonb — ordered list of {lat,lng} vertices),
price_sidewalk, price_driveway, price_both, price_salting, is_active (bool), created_at.
Drives REGIONAL pricing + who can order via GEOFENCED ZONES: the customer's address is
geocoded to a lat/lng point, then tested (point-in-polygon, client-side in Dart —
lib/utils/geo.dart matchZone) against each active zone's `polygon`; the matching zone's
prices apply. NESTED ZONES (2026-07-13): when a point falls inside multiple overlapping
polygons, the SMALLEST-area zone wins (order-independent), so you can drop a premium
"pocket" on top of a bigger zone and it takes precedence — matchZone in BOTH geo.dart AND
the create-checkout-session TS port must stay in lockstep (they each fetch zones with no
ORDER BY, so smallest-wins is what keeps the shown price == the charged price). For just a
few premium homes, prefer the per-address multiplier instead of a nested zone.
No matching zone → can't order ("Not available in your area yet"). Managed
in the admin panel's "Areas" tab via a map-based polygon drawer (lib/screens/admin/
zone_editor_screen.dart). `zips` is a LEGACY fallback: matchZone falls back to zips @> [zip]
only for zones that have no polygon yet (migration safety) or when geocoding failed.
Public SELECT via RLS (so the pre-signup quote can read zones with the anon key).
REQUIRES: `ALTER TABLE service_areas ADD COLUMN IF NOT EXISTS polygon jsonb;`

### waitlist
id, email, zip, address, created_at. Captured when someone's ZIP isn't served yet
(from the order screen banner or the pre-signup quote screen). Read in the admin
Customers tab ("Waiting for us to arrive"), ranked by ZIP — that's the evidence for
which town to open next.

### email_log
id, to_email, subject, body, user_id, lead_id, provider_id, template, sent_by,
created_at. ONE record of every email SnowServ sends a person, written by BOTH
send-admin-email and send-lead-email AFTER the provider confirms delivery.
Admin-read only (is_admin()); deliberately NO insert policy — only the service role
writes, so a client can't fake a delivery record. Surfaces as the green "Emailed
Aug 7" chip on customer/provider/job cards; tapping it lists the history.
Replaces the pattern of bolting another one-off "did we contact them" boolean onto
another table every time this came up (it came up four times). The body is kept on
purpose: re-reading what you promised someone is most of the value, and it's the
context an AI support agent will need.

### account_deletion_feedback
id, role, reason, note, created_at. The exit survey shown before an account is
deleted. Holds NO identifying data — the person just asked to be erased. Read in
the admin Customers tab.

### disputes
id, job_id, customer_id, provider_id, reason, description, status
(pending/resolved/rejected), resolution, resolved_at, created_at, filed_by
('customer'|'provider'). Filed in-app from a COMPLETED job via "Report a problem"
(lib/utils/dispute.dart — shared by both job-history screens; also the App Store
Guideline 1.2 objectionable-content report). Worked in the admin "Disputes" tab:
Resolve / Reject (+ optional resolution note) and a one-tap "Refund customer".
filed_by (2026-07-30) is the side that COMPLAINED — both parties are on every row,
so without it, resolving a dispute couldn't notify anyone (it silently told nobody
before). Set by a BEFORE INSERT trigger `set_dispute_filed_by()` from auth.uid(),
NOT from the client, so it can't be spoofed; the client value is only a fallback
for service-role inserts. Resolving pushes 'dispute_resolved' / 'dispute_closed'
to the FILER via notify-customer or notify-provider — never blind-send to "the
customer", or a provider's complaint leaks to the person they complained about.
The resolution NOTE is internal (admin panel only) and is never pushed.

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
- ⚠️ THE NUMBERS BELOW GO STALE. They are a snapshot of the live Yonkers row, NOT the
  source of truth — an admin can change them in the Areas tab at any time and nothing in
  the repo updates. Before quoting a price to anyone (recruiting copy, marketing, support),
  READ THE DB, don't read this file. Both prices AND storm bands drifted unnoticed once
  (caught 2026-08-04, after the provider recruiting copy had been undercutting every tier
  by ~25%). Quick check with the public anon key:
  `curl -s "$SUPABASE_URL/rest/v1/service_areas?select=*" -H "apikey: <anon>"`
- Yonkers zone as of 2026-08-04: sidewalk $80 · driveway $120 · both $160
- DEICER IS PRICED PER SURFACE (2026-08-04, migration 20260804140000). Three columns:
  price_salting_sidewalk / price_salting_driveway / price_salting (= the BOTH price,
  original column, meaning unchanged). Live Yonkers values as of 2026-08-11 are sidewalk $45 /
  driveway $70 / both $90 — an admin HAS since lowered the per-surface ones, so the
  three-column split is doing real work now, not sitting inert. One flat fee broke when salting rose to $90: a sidewalk-only order was $80 to
  shovel + $90 to salt. Readers coalesce to price_salting so an old zone row can't price
  at $0. ⚠️ customer_home.dart `_priceSalting` and create-checkout-session must pick the
  SAME column for the same selection — one is what's SHOWN, the other what's CHARGED.
- Storm pricing (labeled "Storm pricing" in customer UI; internal var still surge_multiplier):
  base_price × multiplier (live — driven by snow depth via Open-Meteo API).
  Bands are ADMIN-EDITABLE in app_settings.storm_bands (JSON), no longer hardcoded.
  As of 2026-08-04: 0–3": 1.0x, 3–6": 1.2x, 6–10": 1.5x, 10"+: 2.0x
- PER-ADDRESS custom pricing (addresses.price_multiplier numeric, default 1.0): the
  admin's "this property is underpriced" lever. Admin taps a job's address in the admin
  panel (gold "Nx price" chip / blue "Set price") → dialog sets a multiplier (presets
  1.25/1.5/1.75/2x or custom, clamped 0.5–5x). It's BAKED INTO the four zone-price
  getters in customer_home (_perProperty) so the service buttons, deicer add-on, total,
  and the stored base_price all agree for that property; storm surge then stacks on top
  (final = base × surge). Applies to FUTURE orders at that SAVED address only — an
  already-placed job's hold is locked, and "ordering for someone else" is a brand-new
  address so it's always 1.0. Written by a direct admin client .update() (like the other
  admin writes) — gets its admin RLS policy in the pre-launch RLS lockdown.
- Platform commission: 25% (admin panel, app_settings.commission_pct — admin-editable),
  provider payout: 75%
- Payouts: 7-day rolling batch via admin panel
- PAYOUT RAILS = Stripe Connect EXPRESS (#21, 2026-07-13). Providers onboard their
  own bank + identity on Stripe's hosted page (connect-onboard) — we NEVER collect or
  store SSN/bank/DOB/W-9 anymore (those columns were DROPPED from providers). Stripe
  does KYC and files the 1099. We keep only providers.stripe_connect_id + a cached
  providers.payouts_enabled. batch-payouts/process-payout just `transfer` to the
  connected account and SKIP any provider whose payouts_enabled isn't true.
  ⚠️ REQUIRES Stripe Connect + Express enabled in the Stripe dashboard (platform
  profile completed) + 1099-NEC filing turned on — account-level config, not code.

## Sales tax (NY) — STAGED, currently calculating $0
- Snow removal is a TAXABLE service in NY (maintaining real property; the
  "regular contractual basis" exemption is INTERIOR only and does not reach it).
  The WHOLE charge is taxable **including the deicer** — never itemize salt out.
- **SnowServ is the VENDOR OF RECORD** (decided 2026-08-20). We set the price,
  hold the customer, take the payment and dispatch; providers perform the work as
  independent contractors. NY's marketplace-provider rules were written for
  tangible goods and don't cleanly reach a service, so "the provider is the
  seller" would make every individual shoveler a registered vendor — which will
  not happen. Full reasoning: `docs/ny_certificate_of_authority.md`.
- ⚠️ **Do NOT reintroduce facilitator language anywhere customer-facing.**
  "SnowServ connects you with them", "marketplace and payment facilitator" and
  similar were REMOVED from website/terms.html §1, customer_home's order-screen
  disclaimer, and the FAQ, because they contradict a vendor-of-record
  registration. The Provider Service Agreement still carries the old phrasing on
  purpose — it is versioned, and editing it forces every signed provider to
  re-accept. Four documents have to agree: the CoA, the Terms, the app copy and
  the operating agreement.
- ⚠️ **PRODUCT TAX CODE IS LOAD-BEARING.** create-checkout-session sets
  `product_data[tax_code] = txcd_20070007` ("Landscaping — maintenance of
  grounds") explicitly. The Stripe ACCOUNT DEFAULT is "General - Services"
  (txcd_20030000), which Stripe treats as **EXEMPT IN NEW YORK** — NY exempts most
  services and taxes only enumerated ones, so the generic code lands on the exempt
  side and previews **0%**. Left on the default, every order would calculate $0 tax
  forever while looking correctly configured, and as vendor of record we would owe
  it out of margin. Caught 2026-08-20 on Stripe's "Confirm your tax rates" screen,
  the only place it is ever stated out loud.
  This classifies the SERVICE SOLD and is a different question from the NAICS code
  that classifies the BUSINESS (561790, deliberately not landscaping) — no conflict.
  ⚠️ **Verify empirically after the registration goes live**: a Yonkers test order
  must show ~8.875%, not 0%. If it shows 0%, try txcd_20080007 "Repairs to Real
  Property" and re-test.
- MECHANICS: tax is **exclusive** (added ON TOP of the service price) and sourced
  to the **SERVICE address**, not the payer's billing address. create-checkout-
  session sets `automatic_tax[enabled]=true` and writes the service address to the
  Stripe customer with `customer_update[address]='never'`; stripe-webhook records
  `jobs.tax_amount`. Stripe computes the rate — never hardcode one.
- ⚠️ **Stripe Tax registrations do NOT carry over from TEST mode to LIVE mode.**
  They are entirely separate, exactly like the webhook signing secret. Adding NY
  in test mode makes TEST orders calculate tax and does nothing for live. At
  go-live the registration has to be added a SECOND time in Live mode, or the
  first real customer is charged no tax on a taxable service and SnowServ eats it.
  Test: dashboard.stripe.com/test/tax/registrations ·
  Live: dashboard.stripe.com/tax/registrations
- **It currently calculates $0** because no NY registration exists in Stripe Tax.
  The Certificate of Authority was applied for 2026-08-20 (application
  DTF17-2026-052519, DLN 4604477); approval takes about a week.
  ⚠️ **The day someone adds the registration under Stripe → Tax → Registrations,
  live prices jump by the local rate (~8.9% in Yonkers) with no code change.**
  That is expected, not a bug — the order screen already says "Sales tax, if any,
  is calculated at checkout". Place one test order afterwards and confirm the
  price SHOWN equals the price CHARGED.
- First NY return is due **2026-12-20** (period Sep 1 – Nov 30), mandatory even at
  zero sales, $50 minimum penalty.

## Company & legal records (not in this repo's code path)
- **SnowServ LLC** — NY domestic LLC, DOS ID **7962382**, formed **2026-07-09**,
  Delaware County. Sole member **Vincent R. Citarella** (legal name — earlier docs
  said "Vince", and a filing that mismatches the entity record gets rejected).
- Operating agreement EXECUTED 2026-08-20 (NY LLC Law §417, which requires
  adoption within 90 days of formation and is never filed with the state).
  Source: `docs/snowserv_llc_operating_agreement_execution.html`.
- NAICS **561790** (Other Services to Buildings and Dwellings) — the Census index
  entry for standalone driveway snow plowing. NOT 561730 (that is plowing combined
  with landscaping) and NOT 513210 Software Publishers (we publish no software;
  100% of revenue is a cut of snow-removal jobs).
- Recurring: **NY Biennial Statement** every 2 years, $9, due in the formation
  month — first one **July 2028**.

## Payment flow (Stripe Checkout)
- Migrated OFF flutter_stripe → **Stripe Checkout** (hosted page) 2026-07-07 so ONE
  code path serves iOS, Android AND web (Mac/Windows use the web app in a browser).
  flutter_stripe was mobile-only and broke `flutter build web`; Checkout also brings
  Apple Pay / Google Pay for free on its page. NO client-side Stripe SDK anymore.
- iOS still uses Swift Package Manager only — CocoaPods fully deintegrated.
- Flow (lib/screens/customer/customer_home.dart `createJob`):
  1. Client calls `create-checkout-session` with the order SELECTION (services +
     address_mode/address_id or raw addr) + return URLs → gets a hosted Checkout `url`.
     PRICE IS SERVER-AUTHORITATIVE (2026-07-13 security fix): the function requires a
     login, recomputes base/surge/final from the matched zone + the saved address's
     price_multiplier + live snow depth (ignoring any client-sent amount/price), and
     forces metadata.customer_id to the caller. A client CANNOT pay $0.50 for a $165
     job or bill it to another user. Any client `amount_cents` is ignored.
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
- create-payment-intent + get-payment-methods: DELETED 2026-07-29 (legacy flutter_stripe
  era, zero callers). get-payment-methods also took a stripe_customer_id from the request
  with NO ownership check and returned that customer's card brand/last4/expiry — any
  logged-in user could read another customer's card metadata. Source is in git history.
  A stray Supabase "dynamic-endpoint" hello-world template was deleted at the same time.
- refund-job: looks up payment_intent_id on job, issues full Stripe refund
- notify-providers: notifies providers of new job
- notify-provider: notifies single provider (e.g. cancellation)
- notify-customer: notifies customer (e.g. provider cancelled)
- capture-payment: captures the held PaymentIntent when a provider STARTS the job
  (markInProgress → status in_progress); idempotent. NOT on accept.
- notify-dispatch: notifies only the single provider a job was dispatched to
- batch-payouts / process-payout: Express-only (#21). Transfer the provider's cut to
  their stripe_connect_id; skip anyone whose cached payouts_enabled isn't true. No
  raw bank/SSN — they never touch our DB now.
- connect-onboard: verify_jwt on; creates (once) the provider's Stripe Connect Express
  account + a hosted onboarding Account Link, returns the URL. Keyed to the caller's JWT.
- connect-status: verify_jwt on; GETs the Connect account → {onboarded, payouts_enabled},
  caches payouts_enabled on the provider row; ?dashboard=1 also mints an Express dashboard
  login link. Drives the provider "Set up / manage payouts" tile + admin status chip.
- connect-return: verify_jwt=false; plain-text landing page Stripe returns to after
  onboarding (return/refresh states). Same sandbox constraint as checkout-return.
- send-lead-email: ALL provider-lifecycle mail, branded HTML via Resend, admin-gated.
  Takes {lead_id} or {provider_id} (+ optional review_note) and picks the variant
  from the row's actual state — NEVER from which id you passed:
    lead_new · out_of_area (suppresses ALL dollar figures — a lead outside our
    priced zone must not be quoted Yonkers rates) · stalled_signup · pending_review ·
    approved · needs_attention (carries the fix) · declined.
  Prices are computed SERVER-SIDE from the live zone × app_settings.commission_pct,
  never typed into a template or passed by the client. The pay table shows BOTH
  "customer pays" and "you take home" — one column alone reads as "is $60 the job or
  my cut?" and a contractor who guesses low just doesn't reply.
- send-admin-email: free-form subject+body from the admin panel, sent AS SnowServ.
  Admin-gated. Takes a user_id and resolves the address server-side — there is
  deliberately NO `to` parameter, so a stolen admin session can only mail people
  already in our system. Replaces the mailto: drafts, which composed from whatever
  account the admin's mail app defaulted to (Vince's personal Yahoo, twice).
- notify-provider: takes job_id OR provider_id (the latter for messages about the
  PERSON, not a job — approval, needs_attention).
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
- RLS lockdown STAGE 1 done (2026-07-14, migration 20260714120000_rls_lockdown_stage1):
  the public/anon-key READ leak is closed (anon now reads 0 rows from jobs/addresses/
  users/providers; service_areas stays public for the quote). SELECT policies are scoped
  (self / job-counterparty / admin via an is_admin() helper). WRITES are still permissive
  for logged-in users (no app change / no build needed for Stage 1). STAGE 2 WRITTEN (not
  yet applied — would break build 4): migrations 20260714130000 (signup trigger
  handle_new_user) + 20260714140000 (rate_job + provider_release_job RPCs, tight owner/admin
  writes, provider read = own-jobs+open-queue so provider_notes stays private, money/status
  column tamper guards) + client changes (dispatch.dart deleted; decline/cancel/rating call
  RPCs; signup passes metadata). APPLIED AT THE BUILD-5 CUTOVER — see PRELAUNCH.md.

## Provider registration & review (reworked 2026-08-07)
4 steps: Equipment · Insurance · Payouts · Agreement (no identity step — see below). Equipment drives
everything downstream (has_vehicle is DERIVED from equipment=='plow', no toggle);
truck details are optional at signup and chased afterwards, because demanding them
mid-flow means walking out to the driveway, which is where people quit.

An admin reviewing a pending_review application has THREE actions, not two:
- **Approve** → sends a push AND a branded email (go online + connect your bank).
  Before this, approving somebody told them NOTHING and they could sit approved for
  weeks never knowing to go online.
- **Needs attention** → the common case. Pick one of seven concrete reasons (or
  write your own), which sets registration_status back to 'incomplete', stores it in
  providers.review_note, emails it, and pushes it. They land back IN the registration
  flow with an orange banner showing the note — their answers are kept, and
  resubmitting clears it. This is NOT a rejection and must never be worded as one.
- **Decline** → genuinely disqualified only (duplicate account, etc). Short, final
  email with NO stated reason. It deliberately does NOT say "contact support for more
  information" — the old rejection screen did, and that sentence exists only to
  manufacture the support email it pretends to prevent.

## Provider flow
1. Toggle online → loads available jobs (status=requested, dispatched_to=this provider)
2. Accept job → status becomes assigned, job moves to Active Jobs section
3. Start Job → status becomes in_progress. Offers an OPTIONAL "before" photo
   (camera-only, Skip-able, stored in jobs.before_photos[]) — a dispute shield;
   its upload is non-fatal so it never blocks the card-capturing Start.
4. Complete job → status becomes completed. A live completion photo is REQUIRED
   (camera-only — Gallery removed 2026-07-13; the photo is proof-of-work); notes optional.

## On-site location verification (#19, 2026-07-13)
On Start and Complete the provider app takes a fresh Geolocator.getCurrentPosition()
and records the meters to job_lat/lng in jobs.start_distance_m / complete_distance_m.
VERIFY, NOT GATE (decided w/ Vince): a big distance or a null (location denied / no
fix / job never geocoded) NEVER blocks the provider — the required live camera photo
is the fallback proof. Start beyond ~300m shows a soft, overridable "you seem far from
the job" nudge (Start captures the card). Admin job cards show a per-phase chip: 🟢
on-site / 🟠 off-site (distance) / ⚪ unverified, so a human eyeballs off-site/unverified
jobs before the weekly payout. Threshold _kOnSiteMeters=300 (generous for geocode + GPS
error). Does NOT use live tracking — one-shot fix at each tap (see punchlist #25).
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
- ONE dispatcher: the pg_cron `dispatch_jobs()`, running every minute
  (supabase/migrations/*dispatch*). It expires stale offers and dispatches queued jobs
  regardless of any app being open. The old client-side mirror (`dispatchToNearest` in
  lib/utils/dispatch.dart) was DELETED at the RLS Stage 2 cutover — don't reintroduce a
  second dispatcher or go looking for that file; there is nothing left to "keep in sync".
- RANKING (`dispatch_jobs`), in order: equipment fit (a shovel-only provider is pushed
  last ONLY for a large-driveway job) → fewest active jobs → nearest. Eligibility is just
  is_online + registration_status='approved' + not already rejected + not the customer
  themselves.
- NO DISTANCE CAP, deliberately (confirmed w/ Vince 2026-07-29): a provider willing to
  drive two hours into an area and work it is a WIN, not an error, and a radius would
  strand jobs in thin coverage. The provider is shown the distance instead of being
  filtered by it — the offer card and the "Jobs Waiting" cards render a "N mi away" chip
  (`_distanceChip` in provider_home), flagged "· long trip" past 15 mi, so accepting a
  long haul is an informed choice. The chip renders NOTHING when the phone has no fix or
  the job never geocoded — an unknown distance must never read as "right next door".
  Likewise no LOAD cap, so nothing is stranded when everyone is busy.
- PREFERRED-DRIVER OVERRIDE (providers.preferred_until timestamptz, admin-panel toggle
  on the provider card): the admin's "take care of a certain driver" lever. RELATIVE
  rule (not a fixed radius, not an unconditional bump): while the override is live, the
  preferred driver wins a new job ONLY when they're EQUAL-OR-CLOSER to it than the
  driver who'd otherwise be picked — so they're never sent a worse-distance job; the
  override just lets them win the close calls (incl. beating a less-busy-but-farther
  driver). AUTO-EXPIRES at preferred_until (admin picks 4h/8h/24h; no cron).
  dispatch_jobs() picks the normal winner + the nearest live-preferred driver and swaps
  only if pref_dist <= normal_dist. Admin card shows a gold "Preferred · Nh left" badge.
- AUTO-ACCEPT (providers.auto_accept, opt-in toggle on provider home): a job routed to
  an auto-accept provider is assigned directly (status=assigned) instead of a pending
  offer — no countdown to miss. Provider notified via notify-provider status
  'auto_assigned' from BOTH paths: the client calls it directly; the cron calls it
  via pg_net (net.http_post, same pattern as the payout cron) so a closed-app
  provider still gets the push.
- DISPATCH-OFFER WINDOW (admin-editable, 2026-07-13): how long a provider has to
  accept an offered job before it auto-declines + re-dispatches. SINGLE SOURCE OF
  TRUTH = app_settings.dispatch_timeout_seconds (default 240s = 4:00, clamped
  60–600). BOTH the pg_cron dispatch_jobs() expiry (reads the setting via
  make_interval, regex-guarded so a bad value defaults to 240) AND the provider
  UI countdown (AppConfig.dispatchTimeoutSeconds, refreshed on going online) read
  it, so they can never drift. Edit from the admin Jobs tab ("Dispatch offer
  window · Edit"). Supersedes the old hardcoded 3-vs-4-min mismatch (reconciled
  to 4 min on 2026-07-11, now fully config-driven).

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
- Apple Pay as a dedicated integration — NOTE: Stripe Checkout surfaces Apple Pay /
  Google Pay automatically on its hosted page where the device/browser supports it,
  so the wallet buttons come "for free" with the Checkout migration.
  ✅ NO domain registration needed, verified against Stripe's docs 2026-08-04. Stripe
  requires registering a payment-method domain only for **Elements** or **Checkout's
  EMBEDDABLE** payment form — i.e. when the payment UI renders on OUR domain. We use
  the HOSTED redirect to checkout.stripe.com, so the wallet sheet is on Stripe's own
  (already-registered) domain. An earlier note here claimed registration was required
  and caused a false alarm that app.snowserv.app had silently broken Apple Pay.
  ⚠️ This flips the day we ever move to embedded Checkout or the Payment Element —
  then EVERY domain showing the payment form must be registered, live mode included.
  https://docs.stripe.com/payments/payment-methods/pmd-registration

## Deliberately NOT doing (decided, do not re-propose)
- Modifying an order after it's placed (e.g. "add salting" later). Considered and
  rejected 2026-07-05: too confusing and not worth the payment-flow complexity
  (the hold can't be raised, so it needs a new hold / delta charge). If a customer
  forgets an add-on, they cancel and re-book — the instant hold-release makes that
  painless. Order-time selection is the only place to choose services + salting.
- CRIMINAL BACKGROUND CHECKS on providers. Decided 2026-08-07 (Vince): "they're not
  going inside people's houses, so we don't even have to worry about that." The work
  is entirely outdoors — driveways, walkways, sidewalks — and vetting is already
  photo ID + insurance + the signed Provider Service Agreement, with Stripe Connect
  running real KYC before anyone gets paid. ⚠️ The one thing that would change: if we
  EVER decline someone based on a consumer report / background check, the FCRA
  legally requires an adverse-action notice with specific disclosures. That is a
  legal duty, not a style choice — so don't add checks casually.
- COLLECTING ANY IDENTITY DOCUMENT OURSELVES. Decided 2026-08-07 (Vince): "isn't
  that something Stripe might ask for? At the end of the day it's Stripe that's
  issuing the payment to them." Stripe Connect verifies identity properly and it is
  their regulatory obligation; our copy was weaker AND a data liability. Registration
  has no identity step at all now — going ONLINE is gated on payouts_enabled, so
  Stripe's KYC IS the identity gate. Do not re-add an ID upload; there is a test
  (test/registration_layout_test.dart) that fails if one comes back.

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

## Deploys — TWO different sites, two different hosts
| Site | Host | Source | How to deploy |
|---|---|---|---|
| **snowserv.app** (marketing) | Cloudflare Pages, project `snowserv` | `website/` | **`git push`** — the branch IS the deploy |
| **app.snowserv.app** (the Flutter web app) | Firebase Hosting | `build/web` (firebase.json) | `flutter build web && firebase deploy` |

The Pages project is GIT-CONNECTED to `vince79247/snowserv_app-Latest-Version`,
production branch **`geofenced-pricing-zones`** (not `main` — `origin/main` is stuck
at 2026-07-05 and has no `website/` folder), build output directory **`website`**,
no build command, framework preset None. Pushing that branch rebuilds snowserv.app
automatically in ~1 min.

⚠️ This connection was found **completely detached** on 2026-08-09 — Settings → Build
showed an empty "Git repository: Connect" slot, and nothing had deployed for five
days while pushes appeared to succeed. If the site stops updating on push, check
that first; a dropped connection is invisible from outside.

⚠️ ALSO: `origin` is the ONLY offsite backup of this repo. Push after committing.

Cloudflare Pages gotchas:
- **`.html` is stripped**: `/privacy.html` 308s to `/privacy`. Canonical tags and
  internal links must use the extensionless path or they name a URL that redirects.
- Cloudflare rewrites `mailto:` into `/cdn-cgi/l/email-protection` at serve time, so
  live HTML always differs from the repo file there. That's a feature, not drift.
- KNOWN BUG (found 2026-08-08, unfixed): every unknown URL returns the HOMEPAGE with
  HTTP 200 instead of a 404 — a "soft 404" that Google Search Console flags.

## SQL to run (if not done yet)
```sql
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS payment_intent_id text;
-- Geofenced pricing zones (polygon boundary per service_areas row):
ALTER TABLE service_areas ADD COLUMN IF NOT EXISTS polygon jsonb;
-- Per-address custom pricing multiplier (applied + verified 2026-07-10):
ALTER TABLE addresses ADD COLUMN IF NOT EXISTS price_multiplier numeric NOT NULL DEFAULT 1.0;
-- On-site verification distances, meters (applied 2026-07-13, migration 20260713150000):
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS start_distance_m numeric;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS complete_distance_m numeric;
-- Optional provider "before" photos at Start (applied 2026-07-13, migration 20260713160000):
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS before_photos text[];
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
