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
   TIMING (decided 2026-07-11): this is DECOUPLED from App Store / Play Store submission
   — the stores review the app binary, not the database, so RLS state never gates or
   delays a submission or an app update. It's gated to the moment REAL customers sign up
   and enter real data (name/address/card-on-file), since the anon key is public.
   ✅ STAGE 1 DONE (2026-07-14, migration 20260714120000_rls_lockdown_stage1): closed the
   PUBLIC/anon-key READ leak. Inspection had found RLS *enabled* but the policies were
   `USING true` / explicit "Allow anon select" — the anon key (shipped in the app + site)
   could read all jobs (incl. admin-only provider_notes), addresses, users, providers.
   Stage 1 replaced those with scoped SELECT policies (self / job-counterparty / admin;
   service_areas stays public for the quote) while keeping WRITES permissive for logged-in
   users, so NO app change / NO new build was needed. Verified: anon now reads 0 rows from
   every private table; a logged-in customer sees only their own; signup/quote/waitlist
   still work. Reversible via `alter table <t> disable row level security`.
   ✅ STAGE 2 WRITTEN (2026-07-14) — migrations 20260714130000 (signup trigger) +
   20260714140000 (rls_lockdown_stage2) + the matching client changes are all in the repo,
   NOT YET APPLIED (they'd break build 4). Stage 2 moves the client dispatcher +
   customer→provider rating + signup-row creation to SECURITY DEFINER RPCs/trigger
   (rate_job, provider_release_job, handle_new_user; lib/utils/dispatch.dart deleted),
   tightens WRITES to owner/admin-only (+ atomic queue-grab), tightens the approved-provider
   READ to own-jobs+open-queue (so a provider can't read another provider's jobs — and
   provider_notes), and adds money/status column tamper guards. APPLIED AT BUILD-5 CUTOVER
   (see the checklist) + on-device re-tested.
4. **App Store essentials** (iOS only) — privacy-policy URL in App Store Connect,
   metadata + screenshots, and test on a REAL iPhone (not just simulators).
5. **Custom SMTP for auth emails** (you create the account → Claude wires the config).
   Supabase's built-in email is NOT for production — shared reputation, tiny limits,
   hyper-sensitive to bounces. On 2026-07-13 Supabase already WARNED us about a high
   bounce rate (from dev test-signups to made-up @snowserv.app addresses with no real
   mailbox → Zoho rejected them). At real volume the built-in sender will throttle,
   and if it throttles during App Store review the reviewer's confirmation email fails
   → the "broken app" rejection B3 was about. FIX: set up a transactional provider
   (recommend **Resend** — free tier ~3k/mo, easy domain verify; snowserv.app already
   has Cloudflare SPF/DKIM from Zoho) and point Supabase Auth SMTP at it. Vince creates
   the Resend account + API key; Claude PATCHes the Auth SMTP config via the Management
   API. INTERIM until then: don't sign up test accounts with fake addresses — use Gmail
   "+aliases" (all deliver to one real inbox) or create pre-confirmed test users (no
   email sent).

NOT launch blockers — do before you SCALE, not before the first pilot:
- Stripe Connect + Sales Tax epic (design now; a small controlled pilot can run on the
  current manual-payout model — but don't scale without Connect).
- Load test (k6/Artillery) — traffic is tiny at first; matters before multi-town/storm scale.

Low-risk momentum any time: a TestFlight build on your own iPhone, and a marketing
website / pre-signup quote page — the latter needs NONE of the above (no payments).

## Build 5 cutover checklist (security + auth hardening release)
Build 5 bundles several changes that are ALREADY in the repo but must go live together
with matching server-side steps. Do these AT cutover, in order, then upload the build.
Nothing here is live until build 5 ships — build 4 keeps its current behavior.

Repo already contains (client, ships automatically in the build):
- iOS ITMS-90683 fix (NSLocationAlwaysAndWhenInUseUsageDescription re-added to Info.plist).
- Forgot-password = in-app 6-digit CODE flow (reset_password_screen.dart + auth_screen wiring).
- Signup now passes name/phone/role as user metadata and NO LONGER inserts profile rows
  client-side (that's the trigger's job now — see step 2).
- Login/RoleRouter hardened against a missing-profile account (sign out cleanly, no hang).

Server-side steps to run AT cutover (Management API — token in macOS keychain:
`security find-generic-password -s "Supabase CLI" -w`):
1. **Bump** pubspec.yaml `1.0.0+4` → `1.0.0+5`.
2. **Apply the signup trigger** — run migration `20260714130000_signup_handle_new_user_
   trigger.sql` and record it in `supabase_migrations.schema_migrations`. ⚠️ MUST NOT be
   applied before build 5 is the live client (build 4 still inserts rows client-side, and
   the trigger would corrupt provider signups with a defaulted role). Coupled to step-1
   client code.
3. **Set the recovery email template to send the CODE** (the OTP flow needs `{{ .Token }}`;
   the default template only has a magic link). PATCH `mailer_templates_recovery_content`
   via /v1/projects/<ref>/config/auth, e.g.:
   `<h2>Reset your SnowServ password</h2><p>Enter this 6-digit code in the app:</p>
   <p style="font-size:28px;font-weight:bold;letter-spacing:4px">{{ .Token }}</p>
   <p>This code expires in 1 hour. If you didn't request it, ignore this email.</p>`
4. **Apply RLS Stage 2** — migration `20260714140000_rls_lockdown_stage2.sql` (run it
   AFTER the signup trigger in step 2; it revokes the anon inserts the trigger replaces).
   Adds rate_job + provider_release_job RPCs, tightens jobs/providers/users/addresses
   read+write to owner/admin (+ the queue-grab transition), and adds money/status column
   tamper guards. Record it in schema_migrations like the others. ⚠️ Breaks build 4 if
   applied early — this is the whole reason it's a cutover step.
5. Build + upload (the rsync dance — see [[reference-ios-rsync-build-export-conflict]]).

On-device tests after build 5 lands (needs a REAL inbox — mind SMTP blocker #5):
- Signup (real email) → confirm email → log in → lands in the right role home.
- Forgot password → receive code → set new password → log in with it.
- Provider decline & post-start cancel still re-dispatch (RLS Stage 2).
- Rate a completed job (RLS Stage 2 rating RPC).

## Handoff — where we left off (2026-07-07 session, late-night part 2)
Everything committed + pushed to GitHub branch `geofenced-pricing-zones` (not merged to
main; the branch is the de-facto dev branch — 20+ commits ahead, main has none of it;
consider merging to main and cutting named branches going forward). Git auth is the
IDE's GitHub OAuth login. Supabase CLI-linked — Claude can run migrations, deploy edge
functions, and run one-off SQL via `supabase db query --linked "..."`.

**✅ Stripe Checkout is LIVE end-to-end in TEST mode (verified on the sims tonight):**
webhook endpoint registered in the Stripe sandbox (checkout.session.completed),
STRIPE_WEBHOOK_SECRET set. Verified: order → hold → webhook creates job → dispatch →
provider Start captures → post-start-cancel path exercised. Cancel-before-start
releases the hold (seen as payment_intent.canceled in Stripe events).
⚠️ When going LIVE: register a SECOND webhook endpoint in Live mode (different whsec_).

**Also shipped tonight (committed):**
- POST-START CANCEL POLICY (decided w/ Vince): provider cancelling after Start keeps
  the charge; job re-dispatches already paid (idempotent capture = no double charge);
  honest customer push (notify-customer 'provider_cancelled_after_start': "no extra
  charge / cancel for a full refund"); providers.cancelled_after_start_count +
  increment_post_start_cancel RPC (migration applied); red admin-panel badge. Payout
  self-reconciles: 70% goes to whoever COMPLETES (payout keys off jobs.provider_id at
  completion; cancel wipes provider_id).
- Payment copy scrubbed to match the hold model (never "payment received"): return
  page, snackbars, plus custom_text hold note ON the Stripe Checkout page itself.
- Account-menu bottom sheets (provider + customer) made scrollable — fixed the
  14px bottom overflow on iPhone 16 (menus had outgrown the sheet).
- ADMIN ACCOUNTS: profiles.is_admin=true on BOTH vcitarella2004@yahoo.com (customer)
  and amalficoastvacation@yahoo.com (provider, approved) so Vince has admin from the
  provider side too. Revisit account count at RLS lockdown.
- ROADMAP: dual-role accounts entry (one login, both roles — decide post-launch).

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
1. **Finish Checkout platform coverage** — iOS sims are verified; still to test:
   WEB (`flutter run -d chrome`: pay → redirect back → job appears) and Android.
   Verify saved-card reuse + the "card on file" chip on a second order, and that
   Apple/Google Pay show on the hosted page. Register the web domain in Stripe if we
   want the Apple Pay button on web.
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
- 🧊 **Full RLS lockdown** — ✅ Stage 1 shipped 2026-07-14 (closed the public/anon-key
  READ leak; migration 20260714120000). ⏳ Stage 2 (write-hardening: dispatcher/rating/
  signup → SECURITY DEFINER RPCs, strict owner-only writes, job-scoped provider reads,
  column tamper protection) rides on the next build + on-device re-testing. See blocker #3.
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
- ⏳ **Purge the test accounts before launch.** Stripe cleanly separates test and live,
  so every test *connected account* disappears the moment we swap in live keys — but
  our SUPABASE rows do NOT split that way. As of 2026-08-07 that is 6 providers
  (John Doe, Alfonso Citarella, Tony Palma, scott mosby, rosa ramirez, Vinny c) and
  5 customers (Sarah M., Antonio Piazza, joe blow, Jose Toribio, Walter Nichols) —
  some of which are REAL people we are recruiting, so this is not a blind DELETE.
  Do it while we can still tell which is which; that gets harder every week.
  Name new test accounts obviously (`Test Provider (Tony)`) to keep it easy.
  ⚠️ Their JOBS carry the money history — check what a delete cascades into before
  running it, and prefer scrubbing to deleting anywhere a job row is attached.
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
