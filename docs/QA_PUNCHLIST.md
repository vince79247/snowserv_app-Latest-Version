# SnowServ — Full App QA Walkthrough (punch-list)

Living log of a screen-by-screen pass through the whole app. Vince drives the GUI;
Claude watches the DB + logs and records findings. Started 2026-07-12.

**Legend:** 🔴 broken · 🟡 missing/incomplete · 🟢 works as intended · ⚪ not yet tested

## How we're testing
- **Provider surface:** Android emulator (emulator-5554)
- **Customer surface:** web app (localhost:8080) and/or iPhone (TestFlight)
- **Admin:** web or emulator account menu → Admin Panel (is_admin profile)

---

## Findings

| # | Screen / flow | Severity | Finding | Status |
|---|---------------|----------|---------|--------|
| 1 | Customer — active job (requested) | 🟡→✅ | **FIXED.** No prominent reassurance during "Finding provider…". Added a loud orange "Searching for a provider near you — we'll notify you the moment someone accepts" card (with spinner) on every fresh `requested` job. customer_home.dart. Ships build 3. | fixed |
| 2 | Provider — completion photos | 🟡 | Completion photo is **MANDATORY** (provider_home.dart:931-1035: "Photos of completed work are required", Submit disabled until ≥1 photo) — but CLAUDE.md + docs say photos are "optional." Doc mismatch (requirement itself is a sensible proof-of-work policy). Emulator camera can't capture (fake webcam) → tested completion via **Gallery** (pushed a photo to MediaStore). Real-device **camera** path still needs a live test on the iPhone. FIX: correct the docs; retest camera on real device. | doc fix + real-device camera test |
| 3 | Customer — add address / zone pricing | 🟢 | Added 34 Melrose Ave, Yonkers 10710 → order screen showed Driveway $120 + Salting $45 = **$165**, exactly matching the zone. Zone geofence + pricing works. | verified |
| 4 | addresses.lat/lng columns | ⚪ | Columns exist but are null on save — **by design**: geocoding happens at order time (customer_home.dart:523), not on address save. Not a bug; columns are effectively unused (minor cleanup candidate). | not a bug |
| 5 | Provider app (Android emulator) | 🟡 | Emulator VM got **wedged** — ANR, then an APK install died with `Failure calling service package: Broken pipe`. The old instance saved a bad snapshot on shutdown. Root cause looks like **emulator-infra instability** (host disk was ~9GB, corrupt snapshot), not confirmed app code. Cold-booting fresh with `-no-snapshot-load` to retest the app on a clean VM. | cold-boot retest |
| 6 | Payment → job → dispatch pipeline | 🟢 | iPhone paid $165 via Stripe Checkout (hold) → **webhook created job** `6289bd85` (requested, final_price 165, salting ✓) → **dispatch_jobs assigned it to the online provider** (dispatched_at set) — all server-side, verified even with the emulator dead. Core money+dispatch loop works. | verified |
| 7 | Provider — accept job | 🟢 | Accept moved job to `status=assigned`, set provider_id, cleared dispatched_to. Job geocoded to 40.96,-73.83 (Yonkers) stored in job_lat/lng. | verified |
| 8 | Provider — directions/navigation (Android) | 🔴 | `_launchNavigation` (provider_home.dart:648) **always tries Apple Maps first**. On Android there's no Apple Maps app → opens Apple Maps **web** in browser (blank) and, because launchUrl returns true, **never falls back to Google Maps**. iPhone providers fine; Android providers get broken directions. FIX: platform check → Apple Maps on iOS, Google Maps (or geo:) on Android. | open (quick fix) |
| 9 | Provider — Start job / payment capture | 🔴 | HAPPY PATH VERIFIED: Start captured the hold — Stripe shows **$165 "Succeeded"** (support@snowserv.app, "Driveway + Deicer", 1:35 PM). BUT code risk stands: `markInProgress` (provider_home.dart:897-904) sets status=`in_progress` **first**, then invokes capture inside a try/catch that only `debugPrint`s on failure → a capture failure is **silently swallowed** (provider works, job completes, customer never charged, nobody alerted). FIX: on capture failure, flag the job / alert admin / queue a retry. | open (code hardening) |
| 10 | Provider — Complete Job dialog renders blank | 🔴→✅ | **BLOCKING (FIXED).** The completion dialog rendered as a **blank white box** every time — provider literally could not complete a job. ROOT CAUSE: `AlertDialog(content: SingleChildScrollView(...))` — AlertDialog measures its content's **intrinsic width**, but a scroll viewport can't provide one → `RenderViewport does not support returning intrinsic dimensions` → dialog collapses to blank. (NOT the emulator, NOT the photo — reproduces on any device.) FIX 2026-07-12: wrapped content in `SizedBox(width: double.maxFinite, …)` (provider_home.dart). ALSO hardened the picker buttons (try/catch swallowing `already_active` + a `picking` guard disabling both buttons mid-pick) so a double-tap can't corrupt the tree either. Rebuilt on emulator. | fixed, re-testing |
| 11 | Provider — completion photo source (Camera vs Gallery) | 🟡 | DESIGN DECISION for Vince: completion photo is proof-of-work / dispute defense, but the **Gallery** option lets a provider upload a reused/old/fake photo and mark a job complete without being on-site (Uber Eats / DoorDash proof-of-delivery is camera-only for this reason). OPTIONS: (a) camera-only for stronger proof (needs the camera path solid — depends on real-device test #2); (b) keep both but flag gallery-sourced photos in admin so reuse is visible. Decide before launch. | decision pending |
| 12 | Provider — Complete job + photo upload | 🟢 | After the #10 fix, completion worked: status→`completed`, **photo uploaded to job-photos bucket** (verified HTTP 200, 29KB image/jpeg, public URL on the job row). | verified |
| 13 | Customer — rate completed job | 🟢 | Customer rated the completed job ★★★★ on the iPhone → `customer_rating=4` persisted on the job. Full order→…→complete→rate lifecycle verified end-to-end. | verified |
| 14 | Customer — order not visible / not cancellable after paying | 🔴→✅ | **FIXED.** After paying via the mobile Stripe Checkout in-app browser, the just-created order (and its **Cancel** button) didn't appear until a manual refresh — because customer_home had **no app-resume handler** and relied only on the realtime socket, which drops while backgrounded. A customer who paid then couldn't see or cancel their order. FIX 2026-07-12: `_CustomerHomeState` now `with WidgetsBindingObserver` → `didChangeAppLifecycleState(resumed)` calls `loadMyJobs()` + `loadSurge()`, so returning from checkout (or any backgrounding) auto-reloads. Compiles clean; **rides in build 3** (iPhone is on build 1). | fixed, ships build 3 |
| 15 | Customer — cancel before start (hold release) | 🟢 | Cancelled a `requested` $205 order → status→`cancelled`, no provider assigned, **authorization hold released** (never captured, so no charge). Matches the "Canceled"/"Refunded" entries already visible in Stripe. Cancel/refund path verified. | verified |
| 16 | Customer — Pay button spins forever (no timeout) | 🔴 | Tapping Pay set `loading=true` and the spinner **spun for ~1.5 hours** with no recovery. `createJob` awaits `supabase.functions.invoke('create-checkout-session')` (customer_home.dart:1039) with **no timeout**; if it stalls (flaky network / suspended app), `loading` never resets → the whole order is frozen, only escape is force-quitting the app. Real customers on bad wifi would hit this. FIX: add a `.timeout()` to the invoke (and ideally the geocode/service_areas queries) → on timeout, snackbar + reset `loading` so they can retry. | **FIXED** — `.timeout(20s)` on the invoke + friendly timeout snackbar; `loading` resets in finally. Ships build 3. |

---

## Walkthrough checklist (fill in as we go)

### Auth
- [ ] Launch / splash
- [ ] Customer signup (+ email confirmation)
- [ ] Provider signup (+ service agreement e-sign)
- [ ] Login / logout
- [ ] Forgot password

### Customer
- [ ] Add / edit address
- [ ] Service selector + pricing (zone + storm surge + per-address multiplier)
- [ ] Order + Stripe Checkout (hold)
- [ ] Active job states: Finding → Assigned (queue pos) → In progress → Completed
- [ ] Cancel + refund/release
- [ ] My Orders + receipts
- [ ] Rate completed job
- [ ] Remove saved card (NEW)
- [ ] Order for someone else

### Provider
- [ ] Online/offline toggle
- [ ] Available (dispatched) jobs
- [ ] Accept / reject
- [ ] Start (captures hold)
- [ ] Complete (photos + notes)
- [ ] Cancel (before/after start)
- [ ] Auto-accept toggle
- [ ] Job history / earnings
- [ ] Service agreement view

### Admin
- [ ] Jobs list + timeline
- [ ] Manual assign / reassign (NEW)
- [ ] Per-address pricing multiplier
- [ ] Payouts (Process All Payouts)
- [ ] User flags / suspend
- [ ] Areas / zone polygon editor
- [ ] Waitlist view (⚠️ not built yet)
