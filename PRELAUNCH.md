# SnowServ — Pre-launch / Hardening Checklist

Living list of what must happen before real users, in rough priority order.
Status: ✅ done · 🔨 in progress · ⏳ todo · 🧊 later. "Needs you" = requires
Vince (Apple portal, decisions, etc.), not just code.

## Handoff — where we left off (last session)
- Shipped & deployed: regional pricing (service_areas) + availability gate +
  pre-signup quote; storm pricing; real admin auth (profiles.is_admin, no shared
  password — Admin Panel entry in the account menu for is_admin accounts);
  provider-documents locked private + admin-only viewer. All edge functions
  deployed & current; supabase secrets verified.
- Admin account: vcitarella2004@yahoo.com (is_admin=true). Log in normally →
  account menu → Admin Panel. Decided to KEEP this UX for now (not route straight
  to admin) so the account can still test as a customer during the build.
- ⏳ Verify later (manual): provider document viewing end-to-end — register a test
  provider WITH photo uploads, then open them in admin (existing test providers
  have nothing uploaded, so "View" shows nothing — that's correct, not a bug).
- Next candidates: web admin (flutter build web — now unblocked) or Apple sign-in.

## Security hardening
- ✅ Firebase iOS API key restricted to bundle id (Google Cloud Console)
- ✅ Provider documents: private bucket + admin-only signed-URL viewing (admin-doc-url)
- ✅ Secrets server-side only (Stripe secret, service role, Firebase admin)
- 🔨 **Real admin authentication** — replace the shared client-side admin password
  with a real `profiles.is_admin` account; verify server-side in functions.
- ✅ **GitHub token in git remote** — removed the token from the origin URL; now uses
  the macOS Keychain credential helper with a fine-grained PAT (Contents: Read/write,
  scoped to snowserv_app-Latest-Version). Branch pushed 2026-07-07.
  ⚠️ FINAL STEP for Vince: revoke the OLD leaked token on GitHub.
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
