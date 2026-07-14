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
| 8 | Provider — directions/navigation (Android) | ✅ | `_launchNavigation` (provider_home.dart:648) **always tries Apple Maps first**. On Android there's no Apple Maps app → opens Apple Maps **web** in browser (blank) and, because launchUrl returns true, **never falls back to Google Maps**. iPhone providers fine; Android providers got broken directions. **FIXED 2026-07-13:** platform check — Apple Maps on iOS, Google Maps everywhere else (incl. Android/web), each falling back to the other. | ✅ done (build 4) |
| 9 | Provider — Start job / payment capture | ✅ | HAPPY PATH VERIFIED: Start captured the hold — Stripe shows **$165 "Succeeded"** (support@snowserv.app, "Driveway + Deicer", 1:35 PM). BUT code risk stands: `markInProgress` (provider_home.dart:897-904) sets status=`in_progress` **first**, then invokes capture inside a try/catch that only `debugPrint`s on failure → a capture failure is **silently swallowed** (provider works, job completes, customer never charged, nobody alerted). **FIXED 2026-07-13:** a capture failure (thrown OR an error in the response) is no longer swallowed — it sets `jobs.capture_failed`+`capture_error`, tells the provider (non-blocking, keep working), and the admin job card shows a red "Payment not captured" banner with a **Retry** button that re-captures + clears the flag. | ✅ done (build 4) |
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
| 18 | Commission rate — doc mismatch | ✅ | **FIXED 2026-07-13.** Aligned everything to the live **25/75**: CLAUDE.md, the provider agreement (.md — the in-app Dart was already 25), the payout-function fallbacks (batch-payouts/process-payout `?? 25`), and AppConfig's default. The provider-facing "you keep X% of every job" pitch on the registration screen is now **dynamic** (reads AppConfig.commissionPct), so it can never drift from the live rate again. | ✅ done |
| 19 | **Provider can get paid without doing the work** | ✅ | **FIXED (verify-not-gate, per Vince).** On **Start** and **Complete** the app now takes a fresh `getCurrentPosition()` and records the distance to `job_lat/lng` in `jobs.start_distance_m` / `complete_distance_m` (migration 20260713150000). Decided policy: **flag, never block** — the required **live camera-only photo (#11)** is the primary proof, so a null (location denied / no fix / not geocoded) never stops the provider. Start beyond ~300 m shows a soft "you seem far from the job — start anyway?" nudge (overridable, since Start captures the card). Admin job card now shows a per-phase chip: 🟢 on-site / 🟠 off-site (with distance) / ⚪ location unverified, so a human eyeballs off-site/unverified jobs before the weekly payout. Threshold 300 m (generous for geocode + GPS error). Does NOT need live tracking (#25). **Plus optional "before" photo at Start** (2026-07-13): camera-only, Skip-able, non-fatal upload (never blocks the card-capturing Start), stored in new `jobs.before_photos[]`; admin card shows a **before/after** pair. Strengthens dispute defense (snowed-in → cleared). | ✅ done (build 4) |
| 20 | Payouts — providers not onboarded | 🟡 | (Updated for #21 Express.) Payout now requires a provider to finish **Stripe Connect Express** onboarding — until then `batch-payouts` skips them (`reason: 'provider payouts not set up'`). Safe (no crash, no payment). TO TEST payouts end-to-end: a provider taps "Set up / manage payouts" → completes Stripe's hosted flow (test-mode) → `payouts_enabled` flips true → run the batch. Requires Connect/Express enabled in the Stripe dashboard first (#21). | needs Express onboarding to test |
| 21 | **Storing raw SSN + bank numbers in our own DB** | ✅ | **FIXED — migrated to Stripe Connect Express (2026-07-13).** Providers now onboard bank + identity on **Stripe's hosted page** (`connect-onboard` → Account Link); Stripe does KYC and files the 1099. We DROPPED `ssn/dob/bank_routing/bank_account` **and** the W-9 `tax_*` columns — none of that touches our DB anymore. We keep only `stripe_connect_id` + a cached `payouts_enabled`. Registration no longer collects any of it (bank step is now an explainer); the W-9 tax screen was deleted; `batch-payouts`/`process-payout` are Express-only (transfer + skip un-onboarded); `delete-account` also deletes the Connect account; admin card shows a Stripe payout-status chip. Verified: columns dropped on live DB, functions deployed, `connect-return` renders, auth gate returns 401. **⚠️ Vince to do in Stripe dashboard: enable Connect + Express (complete platform profile) + turn on 1099-NEC filing; then run through onboarding on-device to confirm end-to-end.** | ✅ done (build 4) — needs Stripe dashboard enable + on-device test |
| 22 | **No in-app account deletion** | 🔴 | **APP STORE REJECTION BLOCKER.** Apple Guideline **5.1.1(v)** (enforced since Jun 2022): any app supporting account creation **must** offer in-app account deletion. Codebase search finds **zero** delete-account UI for customers OR providers. SnowServ **will be rejected at review**. MUST BUILD before submission: "Delete Account" in the account menu (both roles) → confirm dialog → delete auth user + cascade/anonymize (jobs must be retained for tax/records → anonymize customer_id rather than hard-delete job rows; provider payouts owed must be settled). Also satisfies GDPR/CCPA right-to-delete. | **open — BLOCKS App Store submission** |
| 23 | Provider — can't see paid vs owed | ✅ | **FIXED 2026-07-13.** Provider Job History now reads `payout_status`: the earnings hero shows **Paid out** and **Pending** pills alongside the total, and every job card carries a green **"Paid out"** / amber **"Pending payout"** chip. So a provider can always see what's hit their bank vs. what's still owed. | ✅ done (build 4) |
| 24 | Admin — cannot delete a provider | 🟡 | Admin can only **suspend** (`users.is_suspended` via toggleUserSuspend). No delete path for providers or customers. (Suspend is arguably better for audit/records, but there's no removal at all — and see #22, users must be able to delete themselves regardless.) | open |
| 25 | **Driver location tracking is not real** | 🔴 | Provider GPS is captured **once**, only when they flip the Online toggle (provider_home.dart:175-195: one-shot `getCurrentPosition`, no `getPositionStream`, no background location). `current_lat/current_lng` **goes stale immediately** and is never refreshed — a driver who went online at home shows their home all day. **There is no live driver tracking**, despite the admin map implying otherwise. (This is why the emulator provider read "Mountain View, CA" while completing a Yonkers job.) NOTE: the **geofence fix (#19) does NOT need live tracking** — call `getCurrentPosition()` at the moment of Start/Complete and compare to `job_lat/lng`. Live tracking (background location) is a separate, bigger feature with battery + privacy + App Store "Always" permission implications — decide if it's actually wanted. | open |
