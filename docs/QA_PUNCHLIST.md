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
| 2 | Provider — completion photos | 🟡→✅(docs) | Completion photo is **MANDATORY** — but CLAUDE.md + FAQ used to say "optional." **DOC FIX DONE 2026-07-13:** CLAUDE.md provider flow + the FAQ now state a live completion photo is required (camera-only, #11). Remaining: a real-device **camera** capture test on build 4 (emulator camera is a fake webcam). | ✅ docs fixed · camera test on build 4 |
| 3 | Customer — add address / zone pricing | 🟢 | Added 34 Melrose Ave, Yonkers 10710 → order screen showed Driveway $120 + Salting $45 = **$165**, exactly matching the zone. Zone geofence + pricing works. | verified |
| 4 | addresses.lat/lng columns | ⚪ | Columns exist but are null on save — **by design**: geocoding happens at order time (customer_home.dart:523), not on address save. Not a bug; columns are effectively unused (minor cleanup candidate). | not a bug |
| 5 | Provider app (Android emulator) | 🟡 | Emulator VM got **wedged** — ANR, then an APK install died with `Failure calling service package: Broken pipe`. The old instance saved a bad snapshot on shutdown. Root cause looks like **emulator-infra instability** (host disk was ~9GB, corrupt snapshot), not confirmed app code. Cold-booting fresh with `-no-snapshot-load` to retest the app on a clean VM. | cold-boot retest |
| 6 | Payment → job → dispatch pipeline | 🟢 | iPhone paid $165 via Stripe Checkout (hold) → **webhook created job** `6289bd85` (requested, final_price 165, salting ✓) → **dispatch_jobs assigned it to the online provider** (dispatched_at set) — all server-side, verified even with the emulator dead. Core money+dispatch loop works. | verified |
| 7 | Provider — accept job | 🟢 | Accept moved job to `status=assigned`, set provider_id, cleared dispatched_to. Job geocoded to 40.96,-73.83 (Yonkers) stored in job_lat/lng. | verified |
| 8 | Provider — directions/navigation (Android) | ✅ | `_launchNavigation` (provider_home.dart:648) **always tries Apple Maps first**. On Android there's no Apple Maps app → opens Apple Maps **web** in browser (blank) and, because launchUrl returns true, **never falls back to Google Maps**. iPhone providers fine; Android providers got broken directions. **FIXED 2026-07-13:** platform check — Apple Maps on iOS, Google Maps everywhere else (incl. Android/web), each falling back to the other. | ✅ done (build 4) |
| 9 | Provider — Start job / payment capture | ✅ | HAPPY PATH VERIFIED: Start captured the hold — Stripe shows **$165 "Succeeded"** (support@snowserv.app, "Driveway + Deicer", 1:35 PM). BUT code risk stands: `markInProgress` (provider_home.dart:897-904) sets status=`in_progress` **first**, then invokes capture inside a try/catch that only `debugPrint`s on failure → a capture failure is **silently swallowed** (provider works, job completes, customer never charged, nobody alerted). **FIXED 2026-07-13:** a capture failure (thrown OR an error in the response) is no longer swallowed — it sets `jobs.capture_failed`+`capture_error` and the admin job card shows a red "Payment not captured" banner with a **Retry** button that re-captures + clears the flag. **Admin-only** — the provider isn't shown anything (they can't fix it and are paid for completed work regardless); Start stays non-blocking. | ✅ done (build 4) |
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
| 26 | **Provider sees the customer's real phone number** | 🟡 | **NEEDS A DECISION — raised by Vince 2026-08-10 while answering the Play content-rating questionnaire.** The provider's active-job card (`provider_home.dart:1940-1990`) prints `name · phone` and offers **Call** and **Text** buttons (`tel:` / `sms:` handoff to the native dialer/Messages — nothing is carried in-app). Two problems: (1) it hands both sides a permanent off-platform channel, which is exactly what the **Non-Circumvention clause** of the Provider Service Agreement exists to prevent — "just text me directly next time" costs the platform the customer; (2) it discloses a customer's personal cell to a contractor they've never met, with no way to revoke it after the job. Uber/DoorDash/Lyft all solved this with **masked proxy numbers** (Twilio Proxy or Stripe-adjacent equivalent) so neither party ever sees the other's real digits, and the mask expires with the job. Options to weigh: (a) proxy numbers — correct, costs money per job and needs a Twilio account; (b) drop the phone/Call/Text entirely and rely on the address + notes — free, but a provider who can't find the gate has no recourse; (c) in-app job chat — most work, keeps everything on-platform, and it would flip the IARC "users interact" answer to **Yes** and add a moderation obligation. NOTE: today's **No** on the content-rating questionnaire is still correct precisely because the messaging is a native handoff, not in-app. **RESOLVED 2026-08-11 (Vince): option (b) — the phone number and both buttons are GONE.** *"I don't think the provider should see the customer's real phone number. If he wants to poach a customer, let him work for it. We shouldn't make it easy."* The provider card now shows the customer's NAME only, and `provider_home`'s job query no longer even SELECTs `phone`, so it never reaches the device. What replaced it: the customer's order note now asks a question ("Gate code, where to pile the snow, what to avoid") and **persists per address**, prefilled from the last order at that property, so it is typed once instead of every storm — the customer-authored twin of `address_notes`. Proxy numbers were considered and DEFERRED, not rejected: snow removal needs no rendezvous (nobody has to be home), so unlike a food delivery nothing *requires* live contact. If real storms show the note is insufficient, masked numbers are the next step — do NOT restore the raw phone. | ✅ done (build 20) |
| 27 | **7-year retention is promised but never enforced** | 🟡 | `website/delete-account.html` publicly commits that scrubbed job and payment records "are retained for **seven (7) years** from the date of the job... after which they are deleted", and the Play Data safety declaration now links that page as the delete-data URL. **Nothing implements it.** No cron, no scheduled function, no retention job exists in `supabase/migrations/` or `supabase/functions/` — `delete-account` scrubs PII on request but nothing ever ages records out. So the deletion half of the promise is unbacked: a job row from 2026 will still be sitting there in 2040. Fix is small — a pg_cron job that deletes `jobs` (and their orphaned `addresses`) older than 7 years, same pattern as the existing dispatch/payout crons. Raised 2026-08-10 by Vince while reading the Data safety preview. Related but distinct from admin job **archiving** (a UI concern, already on the list). **DONE 2026-08-11** — migration `20260811120000_retention_purge.sql`: `purge_expired_records()` deletes disputes first (their FK is NO ACTION and would otherwise block the job delete), then jobs past the 7-year cutoff, then only those addresses left with no jobs AND no owner — a live customer's saved address is never swept up because an old job aged out. Scheduled monthly via pg_cron ('20 3 1 * *'). Verified on the live DB: dry run returned 0/0/0 (oldest job is 2026-07-29), cron active, 4 jobs and 16 addresses untouched. **Why seven survives the research:** NY Tax Law §1135 requires sales-tax records for THREE years (Department may demand longer) and the IRS baseline is three, six for substantial understatement — so 7 is longer than either floor and cannot purge something still demandable. If the number ever changes, change it in the migration AND on website/delete-account.html in the same commit. | ✅ done |

---

## Admin: the Areas tab shows a stale `is_active` across devices

**Found 2026-09-05 by Vince.** He turned the Yonkers zone ON in the web admin,
then opened the admin panel on his phone and it still showed the zone OFF, so he
toggled it again there.

**Not a failed write.** `_toggleAreaActive` does a real update and then calls
`loadAll()`. The database was correct the whole time; the phone was displaying
what it had loaded before the change.

**Cause — one missing table.** `_subscribeLive()` (admin_screen.dart ~line 102)
already gives the admin panel debounced live refresh, but only for three tables:

```dart
for (final table in ['jobs', 'providers', 'disputes']) {
```

`service_areas` is not among them, so nothing tells a second device to re-read.

**Fix — add it to the list:**

```dart
for (final table in ['jobs', 'providers', 'disputes', 'service_areas']) {
```

Everything else already exists: `_scheduleRefresh()` debounces the refetch, and
`loadAll()` re-reads `service_areas` at line 207.

**Why it is worth doing.** `is_active` is the single switch that decides whether
ANY customer can order. A stale "on" tells the admin the business is open when it
is closed. The write is safe either way — the toggle computes from the value that
device is showing, so the value written always matches what the operator intended
by looking at the screen — but being misinformed about whether ordering is live is
its own problem.

**Also worth adding while in there:** a `RefreshIndicator` on the admin tabs.
There is currently no pull-to-refresh anywhere in the admin panel, so a stale view
has no manual escape hatch either.

**Deliberately not applied 2026-09-05** — Vince was mid-test on freshly switched
live Stripe keys, and deploying the Flutter web app is a larger action than the
change itself. Apply it in the same pass as the next web deploy.

---

## 🔴 Customer "Cancel request" can hang forever, silently

**Hit live 2026-09-06 by Vince**, on the first real-money order. He pressed Cancel,
confirmed "Yes, Cancel", and the screen froze. Server-side: **zero `refund-job`
calls** in 45 minutes and the job still `requested`. He had to cancel the
PaymentIntent by hand in the Stripe dashboard.

### Why (customer_home.dart ~1599-1631)

```dart
if (confirm != true) return;
try {
  final job = myJobs.firstWhere((j) => j['id'].toString() == jobId, orElse: () => {});
  if (job['payment_intent_id'] != null) {
    final resp = await supabase.functions.invoke('refund-job', body: {'job_id': jobId});
    ...
  }
  await supabase.from('jobs').update({'status': 'cancelled', ...}).eq('id', jobId);
```

Four separate problems, in severity order:

1. **No timeout on the invoke.** If the network stalls the await never returns, so
   the UI sits there forever. Nothing is shown to the user — no spinner, no error,
   no way out. This is what Vince hit.
2. **No loading state at all.** "Frozen" is literally accurate: the button does
   not disable and nothing indicates work is in flight, so the user cannot tell a
   hang from a dead button and will tap repeatedly.
3. **The status update runs AFTER the refund and is not atomic with it.** A refund
   that succeeds followed by a failed update leaves a released hold on a job still
   `requested` — which `dispatch_jobs()` will happily offer to a provider, who
   drives out and then cannot be paid because `capture-payment` has nothing to
   capture.
4. **`payment_intent_id` is read from the LOCAL `myJobs` list, not the database.**
   If that list is stale the guard is false, the refund is skipped entirely, and
   the job is marked cancelled while the hold stays live until it expires — with
   the customer having just been told *"you were never charged."* That is the
   inverse of what happened and arguably worse, because nobody notices.

### Fix — move the whole cancel server-side

Make `refund-job` do the status update itself, inside the same call: it already
receives `job_id`, can read `payment_intent_id` from the row (authoritative, not
stale), cancel or refund the PI, and set `status='cancelled'` — atomically. The
client then makes ONE idempotent call it can safely retry.

Client side, regardless:
- **Timeout the invoke** (~20s) and show a real error.
- **Disable the button and show a spinner** while in flight.
- On failure say something true and useful — *"We couldn't cancel just now. Your
  card has not been charged. Try again, or email support@snowserv.app"* — rather
  than leaving a frozen screen over someone's held money.

**This is the most serious defect found to date.** A customer whose cancel hangs
sees their money held with no way out and no explanation.

---

## Customers will read the authorization hold as a charge

**Raised 2026-09-06 by Vince**, after watching his own bank app during the live
test: an $80 pending line appeared, then reversed.

**Nothing is wrong.** An authorization hold does reduce available balance and does
display as pending — banks have no way to render "reserved but not taken". No
money moved.

**But he built this app, knows the payment model exactly, and still asked.** A
customer who has never heard "authorization hold" will be certain they were
charged. That is a support email, or a one-star review, on the first order.

### The copy already exists — in the wrong place

The FAQ answers it, and the cancel snackbar says *"you were never charged."* Both
are correct and both are invisible at the moment the confusion actually happens:
an hour later, in a banking app, nowhere near SnowServ.

### Fix — put it where the doubt occurs

Add it to the **order confirmation** and, better, the **push notification** sent
when the job is created. Something like:

> **$80 is held on your card, not charged.** You're only charged when a provider
> starts the job.

That reaches them before they open their bank, instead of after. The order screen
note is good but it is read *before* paying, when nobody is worried yet.
