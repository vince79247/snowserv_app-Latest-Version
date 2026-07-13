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
| 1 | Customer — active job (requested) | 🟡→✅ | **FIXED.** No prominent reassurance during "Finding provider…". Added a loud orange "Searching for a provider near you — we'll notify you the moment someone accepts" card (with spinner) on every fresh `requested` job. customer_home.dart. **Verified on iPhone build 3.** | ✅ verified on device |
| 2 | Provider — completion photos | 🟡 | Completion photo is **MANDATORY** (provider_home.dart:931-1035: "Photos of completed work are required", Submit disabled until ≥1 photo) — but CLAUDE.md + docs say photos are "optional." Doc mismatch (requirement itself is a sensible proof-of-work policy). Emulator camera can't capture (fake webcam) → tested completion via **Gallery** (pushed a photo to MediaStore). Real-device **camera** path still needs a live test on the iPhone. FIX: correct the docs; retest camera on real device. | doc fix + real-device camera test |
| 3 | Customer — add address / zone pricing | 🟢 | Added 34 Melrose Ave, Yonkers 10710 → order screen showed Driveway $120 + Salting $45 = **$165**, exactly matching the zone. Zone geofence + pricing works. | verified |
| 4 | addresses.lat/lng columns | ⚪ | Columns exist but are null on save — **by design**: geocoding happens at order time (customer_home.dart:523), not on address save. Not a bug; columns are effectively unused (minor cleanup candidate). | not a bug |
| 5 | Provider app (Android emulator) | 🟡 | Emulator VM got **wedged** — ANR, then an APK install died with `Failure calling service package: Broken pipe`. The old instance saved a bad snapshot on shutdown. Root cause looks like **emulator-infra instability** (host disk was ~9GB, corrupt snapshot), not confirmed app code. Cold-booting fresh with `-no-snapshot-load` to retest the app on a clean VM. | cold-boot retest |
| 6 | Payment → job → dispatch pipeline | 🟢 | iPhone paid $165 via Stripe Checkout (hold) → **webhook created job** `6289bd85` (requested, final_price 165, salting ✓) → **dispatch_jobs assigned it to the online provider** (dispatched_at set) — all server-side, verified even with the emulator dead. Core money+dispatch loop works. | verified |
| 7 | Provider — accept job | 🟢 | Accept moved job to `status=assigned`, set provider_id, cleared dispatched_to. Job geocoded to 40.96,-73.83 (Yonkers) stored in job_lat/lng. | verified |
| 8 | Provider — directions/navigation (Android) | 🔴 | `_launchNavigation` (provider_home.dart:648) **always tries Apple Maps first**. On Android there's no Apple Maps app → opens Apple Maps **web** in browser (blank) and, because launchUrl returns true, **never falls back to Google Maps**. iPhone providers fine; Android providers get broken directions. FIX: platform check → Apple Maps on iOS, Google Maps (or geo:) on Android. | open (quick fix) |
| 9 | Provider — Start job / payment capture | 🔴 | HAPPY PATH VERIFIED: Start captured the hold — Stripe shows **$165 "Succeeded"** (support@snowserv.app, "Driveway + Deicer", 1:35 PM). BUT code risk stands: `markInProgress` (provider_home.dart:897-904) sets status=`in_progress` **first**, then invokes capture inside a try/catch that only `debugPrint`s on failure → a capture failure is **silently swallowed** (provider works, job completes, customer never charged, nobody alerted). FIX: on capture failure, flag the job / alert admin / queue a retry. | open (code hardening) |
| 10 | Provider — Complete Job dialog renders blank | 🔴→✅ | **BLOCKING (FIXED).** The completion dialog rendered as a **blank white box** every time — provider literally could not complete a job. ROOT CAUSE: `AlertDialog(content: SingleChildScrollView(...))` — AlertDialog measures its content's **intrinsic width**, but a scroll viewport can't provide one → `RenderViewport does not support returning intrinsic dimensions` → dialog collapses to blank. (NOT the emulator, NOT the photo — reproduces on any device.) FIX 2026-07-12: wrapped content in `SizedBox(width: double.maxFinite, …)` (provider_home.dart). ALSO hardened the picker buttons (try/catch swallowing `already_active` + a `picking` guard disabling both buttons mid-pick) so a double-tap can't corrupt the tree either. Rebuilt on emulator. | fixed, re-testing |
| 11 | Provider — completion photo source (Camera vs Gallery) | ✅ | **DECIDED + DONE: camera-only.** Gallery button removed from the Complete Job dialog (provider_home.dart) — the completion photo must be a live capture taken at the job, matching Uber Eats / DoorDash proof-of-delivery. This is also the fallback proof behind the #19 geofence (verify-not-gate). Copy updated: "A live photo of the completed work is required." | ✅ done (build 4) |
| 12 | Provider — Complete job + photo upload | 🟢 | After the #10 fix, completion worked: status→`completed`, **photo uploaded to job-photos bucket** (verified HTTP 200, 29KB image/jpeg, public URL on the job row). | verified |
| 13 | Customer — rate completed job | 🟢 | Customer rated the completed job ★★★★ on the iPhone → `customer_rating=4` persisted on the job. Full order→…→complete→rate lifecycle verified end-to-end. | verified |
| 14 | Customer — order not visible / not cancellable after paying | 🔴→✅ | **FIXED.** After paying via the mobile Stripe Checkout in-app browser, the just-created order (and its **Cancel** button) didn't appear until a manual refresh — because customer_home had **no app-resume handler** and relied only on the realtime socket, which drops while backgrounded. A customer who paid then couldn't see or cancel their order. FIX 2026-07-12: `_CustomerHomeState` now `with WidgetsBindingObserver` → `didChangeAppLifecycleState(resumed)` calls `loadMyJobs()` + `loadSurge()`, so returning from checkout (or any backgrounding) auto-reloads. Compiles clean; **rides in build 3** (iPhone is on build 1). **Verified on iPhone build 3** — order card + Cancel button appear on return with no manual refresh. | ✅ verified on device |
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

---

## Admin panel leg (2026-07-13)

| # | Screen / flow | Severity | Finding | Status |
|---|---------------|----------|---------|--------|
| 17 | Admin — earnings & payout math | 🟢 | VERIFIED against DB: $489 earnings @ **25% commission**, from $1,954 collected, providers earned $1,466. Per-job split correct ($120 → $90/$30). Earnings-by-storm totals reconcile (20 jobs, $1,954). **Cancelled jobs (130) correctly EXCLUDED from revenue.** "(14 due)" = the 7-day rolling payout cutoff working as designed (14 completed jobs >7d old, $1,330). | verified |
| 18 | Commission rate — doc mismatch | 🟡 | `app_settings.commission_pct = **25**` (set 2026-07-09, admin-editable via "Edit rate"), but **CLAUDE.md says 30%** / provider 70%. Money-critical number documented wrong. FIX: update CLAUDE.md to 25/75 (or reset the setting to 30 if 30 was intended). | open (doc fix) |
| 19 | **Provider can get paid without doing the work** | ✅ | **FIXED (verify-not-gate, per Vince).** On **Start** and **Complete** the app now takes a fresh `getCurrentPosition()` and records the distance to `job_lat/lng` in `jobs.start_distance_m` / `complete_distance_m` (migration 20260713150000). Decided policy: **flag, never block** — the required **live camera-only photo (#11)** is the primary proof, so a null (location denied / no fix / not geocoded) never stops the provider. Start beyond ~300 m shows a soft "you seem far from the job — start anyway?" nudge (overridable, since Start captures the card). Admin job card now shows a per-phase chip: 🟢 on-site / 🟠 off-site (with distance) / ⚪ location unverified, so a human eyeballs off-site/unverified jobs before the weekly payout. Threshold 300 m (generous for geocode + GPS error). Does NOT need live tracking (#25). | ✅ done (build 4) |
| 20 | Payouts — providers not onboarded | 🟡 | Neither test provider has payout details (`stripe_connect_id`, `bank_account`, `bank_routing`, `ssn`, `dob` all NULL), so **"Process All Payouts" would skip both** (`batch-payouts` → `reason: 'missing bank info or SSN'`). Safe (no crash, no payment) but nothing disburses. $1,465.50 currently owed across 20 completed jobs. The collection UI DOES exist (provider_home.dart:379-453 bank form; provider_tax_info_screen.dart for SSN/W-9) — providers just haven't completed it. TO TEST payouts end-to-end: fill in a provider's bank + tax info first. | needs provider onboarding to test |
| 21 | **Storing raw SSN + bank numbers in our own DB** | 🔴 | `providers.ssn`, `.bank_account`, `.bank_routing`, `.dob` are plaintext columns in Supabase; `batch-payouts` reads them to build Stripe Connect **custom** accounts. This makes SnowServ the custodian of providers' **Social Security numbers and bank credentials** — a severe breach/compliance liability for a solo founder, and it's avoidable. FIX (pre-launch, strongly recommended): switch to **Stripe Connect Express hosted onboarding** — Stripe collects + verifies SSN/bank/DOB (KYC) and returns only a `stripe_connect_id` (column already exists). We stop collecting/storing the raw fields entirely, and drop those columns. Reduces liability AND removes the KYC burden. | open (pre-launch, high priority) |
| 22 | **No in-app account deletion** | 🔴 | **APP STORE REJECTION BLOCKER.** Apple Guideline **5.1.1(v)** (enforced since Jun 2022): any app supporting account creation **must** offer in-app account deletion. Codebase search finds **zero** delete-account UI for customers OR providers. SnowServ **will be rejected at review**. MUST BUILD before submission: "Delete Account" in the account menu (both roles) → confirm dialog → delete auth user + cascade/anonymize (jobs must be retained for tax/records → anonymize customer_id rather than hard-delete job rows; provider payouts owed must be settled). Also satisfies GDPR/CCPA right-to-delete. | **open — BLOCKS App Store submission** |
| 23 | Provider — can't see paid vs owed | 🟡 | job_history_screen.dart:59 shows only a single **"Total Earnings"** figure (sum of their cut on completed jobs). It never reads `payout_status`, so a provider **cannot tell what's been paid to their bank vs. what's still owed**. With 7-day rolling + manual weekly payouts, providers will absolutely ask "where's my money?" FIX: split into **Paid** vs **Pending** using `jobs.payout_status`, ideally with payout dates. Trust/retention issue. | open |
| 24 | Admin — cannot delete a provider | 🟡 | Admin can only **suspend** (`users.is_suspended` via toggleUserSuspend). No delete path for providers or customers. (Suspend is arguably better for audit/records, but there's no removal at all — and see #22, users must be able to delete themselves regardless.) | open |
| 25 | **Driver location tracking is not real** | 🔴 | Provider GPS is captured **once**, only when they flip the Online toggle (provider_home.dart:175-195: one-shot `getCurrentPosition`, no `getPositionStream`, no background location). `current_lat/current_lng` **goes stale immediately** and is never refreshed — a driver who went online at home shows their home all day. **There is no live driver tracking**, despite the admin map implying otherwise. (This is why the emulator provider read "Mountain View, CA" while completing a Yonkers job.) NOTE: the **geofence fix (#19) does NOT need live tracking** — call `getCurrentPosition()` at the moment of Start/Complete and compare to `job_lat/lng`. Live tracking (background location) is a separate, bigger feature with battery + privacy + App Store "Always" permission implications — decide if it's actually wanted. | open |
