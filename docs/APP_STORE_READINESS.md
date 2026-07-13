# SnowServ — App Store Submission Readiness Audit

Audited 2026-07-13 against the App Store Review Guidelines. Companion to `QA_PUNCHLIST.md`.

**Verdict: NOT ready to submit.** 3 blockers, 4 high-risk items. All are fixable.

---

## 🔴 BLOCKERS — will get you rejected

### B1. No in-app account deletion — Guideline 5.1.1(v)
Any app supporting account creation **must** let users delete the account **in-app**. Enforced
since June 2022. Codebase has **zero** delete-account UI (customer or provider). This is an
automatic rejection.

**Build:** "Delete Account" row in the account menu (both roles) → confirmation → edge function
deletes the auth user. **Do NOT hard-delete job rows** (needed for tax/payout records) —
anonymize the person on old jobs instead. A provider with **unpaid earnings must be settled**
(or blocked from deleting) first.

### B2. iPad is declared but not supported — Guideline 2.1 / 4.0
`TARGETED_DEVICE_FAMILY = "1,2"` in `ios/Runner.xcodeproj/project.pbxproj` means the app claims
**iPhone AND iPad**. Apple **will** review it on an iPad. The UI was never designed or tested
there.

**Fix (recommended): set `TARGETED_DEVICE_FAMILY = "1"` (iPhone only).** A snow-removal app for
homeowners and drivers has no iPad use case, and this removes an entire rejection surface for
free. (Alternative: actually design + test iPad layouts — far more work, no benefit.)

### B3. Email-confirmation link is broken — Guideline 2.1 (App Completeness) — ✅ FIXED 2026-07-13
Email confirmation is ON (users must confirm before login), but the link in the email lands on
**"Safari can't find the server"** — the Supabase **Site URL / redirect** is misconfigured.
**A reviewer creating an account hits a broken page.** That reads as a broken app.

**Fix:** set the correct Site URL + redirect allow-list in Supabase Auth settings, and verify the
full signup → email → confirm → login flow end to end.

**DONE 2026-07-13:** root cause was `site_url = http://localhost:3000` (Supabase default). PATCHed
`site_url` + `uri_allow_list` (via Management API, targeted — email-confirmation left ON) to the new
`auth-confirmed` edge function, which shows an honest "you're all set / log in" page. Verified the
verify endpoint now redirects there (was dead). NOTE: Supabase reports verify errors in the URL
**fragment**, unreadable by a sandboxed edge-fn page — so the copy is worded to be true whether the
link worked or expired. A branded page that reads the fragment needs a non-sandboxed host (tracked).
Password-reset redirect is a SEPARATE flow (still uses site_url; handle in the auth-edges leg).

---

## 🟡 HIGH RISK — fix before submitting

### H1. No way to report content or raise a dispute — Guideline 1.2
Providers upload **completion photos** that are shown to customers — that's user-generated
content. Guideline 1.2 wants a way to **report objectionable content** and **block abusive
users**. Today the FAQ just says "email support@snowserv.app."

Risk is moderate (photos are private to one job, not a public feed), but a strict reviewer can
flag it — **and it's the same feature as the dispute mechanism you want**. Build once, solve both:
an in-app **"Report a problem with this job"** flow (customer *and* provider) that files a dispute
the admin can see and resolve. Schema already anticipates it (`users.dispute_count`, `is_flagged`).

### H2. Location purpose string is inaccurate (and will get more so) — ✅ FIXED 2026-07-13
`NSLocationWhenInUseUsageDescription` previously said only *"to check current snow conditions and
calculate accurate pricing"* — but location is also used for provider dispatch/proximity and now,
with the geofence (#19), to verify the provider is at the job site on Start/Complete. Apple rejects
purpose strings that don't match actual use.

**DONE:** rewrote the when-in-use string to cover all three real uses (pricing, nearby-job matching,
on-site confirmation) and note it's used only while the app is in use. Also **dropped
`NSLocationAlwaysAndWhenInUseUsageDescription`** — the app only ever uses when-in-use (one-shot
`getCurrentPosition`, no background/`getPositionStream`), so declaring "Always" only invited scrutiny.

### H3. Stripe TEST → LIVE sequencing trap
The Stripe keys are **not in the app binary** (the Checkout migration removed the client SDK) —
they're the server-side Supabase secret `STRIPE_SECRET_KEY`. This is good (swap without a rebuild)
but creates a trap:

- **During review, the secret MUST stay a TEST key** — the reviewer notes tell them to pay with
  `4242 4242 4242 4242`. With a LIVE key that card **fails** → rejection.
- **After approval, before release, swap to the LIVE key** AND register a **second webhook
  endpoint in Stripe Live mode** (different `whsec_`). Miss this and **real customers cannot pay.**

Get the order wrong in either direction and you either fail review or ship a broken store.

### H4. Placeholder/test data visible
Provider `amalficoastvacation@yahoo.com` is named **"John Doe"**; a customer has phone
`123456789`. Clean up test data before launch — sloppy, though not itself a rejection.

---

## ✅ PASSING — verified

| Item | Status |
|---|---|
| Permission purpose strings (Location, Camera, Photo Library) | ✅ present + accurate wording aside |
| Privacy Policy + Terms linked in-app (`lib/utils/legal.dart`) | ✅ |
| Support contact (support@snowserv.app, FAQ) | ✅ |
| Location **denied** → app degrades gracefully, no crash | ✅ |
| Physical services → Stripe is correct, **not** IAP (Guideline 3.1.3(e)) | ✅ |
| No third-party login → **Sign in with Apple not required** (4.8) | ✅ |
| Export-compliance declaration baked into Info.plist | ✅ |
| Age rating + App Privacy questionnaire | ✅ done |
| Demo review account (support@snowserv.app) exists and works | ✅ |
| Completion-dialog blank-box crash | ✅ **fixed in build 3** (would have been a rejection) |

---

## Not App Store blockers, but launch-critical (see QA_PUNCHLIST)
- ~~**#19** Provider can get paid without doing the work (no geofence)~~ — ✅ FIXED 2026-07-13
  (on-site distance recorded + flagged on Start/Complete; camera-only live photo; admin review chips)
- ~~**#21** Raw SSNs + bank numbers stored in our DB~~ — ✅ FIXED 2026-07-13 (migrated to
  Stripe Connect Express hosted onboarding; ssn/bank/dob/tax_* columns dropped; Stripe does
  KYC + files 1099s). Needs Connect/Express enabled in the Stripe dashboard + an on-device test.
- **#23** Providers can't see paid vs. owed — trust/retention

---

## Recommended order
1. **B2 iPad → iPhone-only** (one line, removes a whole rejection surface)
2. **B1 Account deletion** (the real build)
3. **B3 Email-confirmation redirect** (Supabase config + verify)
4. **H1 Dispute / report flow** (also satisfies Guideline 1.2)
5. **H2 Location purpose strings** (do alongside the #19 geofence)
6. **H4 Clean test data**
7. **H3** — a **release-day checklist item**, not a code change

---

## Security review (2026-07-13) — findings + fixes
- **Price manipulation (MEDIUM) — FIXED + VERIFIED.** `create-checkout-session` trusted the
  client-supplied `amount_cents` + `metadata.final_price`; a logged-in customer could pay 50¢
  for a $165 job. Fixed: the function now recomputes base/surge/final server-side from the
  matched zone + saved-address multiplier + live snow depth, forces `customer_id` to the
  authenticated caller, and verifies a saved `address_id` belongs to them. Verified end-to-end:
  a tampered 50¢ request priced the real $165; foreign address_id / out-of-zone / no-service all
  rejected. Client needs no change (edge fn already live).
- Reviewed clean: `delete-account` (own-JWT keyed, no IDOR), `auth-confirmed` (no reflection),
  dispute RLS (admin-only resolve), `stripe-webhook` (signature + replay protection).
