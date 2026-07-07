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
Everything below is committed AND pushed to GitHub branch `geofenced-pricing-zones`
(not merged to main). Git auth is the IDE's GitHub OAuth login (leaked PAT deleted).
Supabase project is CLI-linked — Claude can run migrations (`supabase db push`) and
deploy edge functions. All new migrations applied; notify-provider redeployed.

**Shipped this session (all committed + verified on the iOS sims unless noted):**
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

**➡️ NEXT TASK (what to start the new chat on): migrate payments to Stripe Checkout.**
- Why: app uses `flutter_stripe` (custom PaymentIntent flow) which is MOBILE-ONLY
  (iOS/Android) and won't compile for web (`flutter build web` currently FAILS on it).
  Goal is multi-platform: iOS, Android, + WEB — and Mac/Windows are served by the WEB
  app in a browser, NOT native desktop builds. Checkout = one integration for all +
  free Apple Pay/Google Pay + native Stripe Tax.
- MUST preserve the authorize-and-capture model: create the Checkout Session with
  `payment_intent_data.capture_method='manual'` → hold at order, capture at provider
  START, release on cancel-before-start. Underlying object stays a PaymentIntent, so
  capture-payment + refund-job carry over — grab `session.payment_intent`, store on the
  job like today. Confirmed with Vince this keeps the "no charge unless provider starts"
  promise intact.
- Part of the SAME epic as Stripe Connect + Sales Tax (see ROADMAP) — platform is the
  tax collector of record; ideally design together.

**Other open threads:** marketing website (separate, SEO-friendly, NOT Flutter web);
web app (Flutter web, unblocked once Checkout replaces flutter_stripe); founder critical
path = LLC + EIN + CPA/sales-tax (gates real money). See "Go-live blockers" above.

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
