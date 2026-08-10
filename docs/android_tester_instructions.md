# Android tester instructions (text-friendly)

For a remote tester on a physical Android via Firebase App Distribution.
Tester: tpiazza@precisionmarblegranite.com (registered; build 12 distributed 2026-07-29).

## Gotchas that stall testers
1. The invite email MUST be opened **on the Android phone** (the link installs a phone app).
2. He must sign in with the **same Google/email account the invite was sent to**.
3. **Email confirmation is ON** — after signing up in SnowServ he must click the confirm
   link in his email before he can log in. This is the #1 place testers get stuck.
4. The address must be in a **served zone** — currently **Yonkers, NY only**. His own
   address will NOT work. Give him a Yonkers address to type (e.g. 34 Melrose Ave,
   Yonkers, NY 10710).
5. **Stripe test card only**: 4242 4242 4242 4242, any future expiry, any CVC, any ZIP.
   No real money moves. Never let a tester use a real card.
6. The emulator can't finish Stripe Checkout (packet loss) — a real device on a real
   network is exactly why this test matters. See reference-emulator-stripe-checkout.

## PART 1 — Install (one time)

### Preferred route since 2026-08-10: Play Internal testing
The app is now on a real **Google Play internal testing track** (build 18 published
2026-08-10, the first Android release build this project ever produced). This is
better than Firebase App Distribution for testers — it installs from the Play Store
like a normal app, with no "install unknown apps" prompt and no separate tester app.

**Opt-in link:** https://play.google.com/apps/internaltest/4701390551575953453

1. Open that link **on the Android phone**, signed into a Google account that is on
   the tester email list (Play Console → Test and release → Testing → Internal
   testing → Testers → list "Internal"). Currently on it:
   `snowserv.app@snowserv.app` and `vcitarella2004@yahoo.com`.
   ⚠️ **A tester whose account is not on that list gets a dead page.** Add Tony's
   Gmail to the list before sending it to him.
2. Tap **Become a tester**, then the **Download it on Google Play** link.
3. Install from the Play Store page as normal.

Until the Main store listing is filled in, testers see a **temporary app name** on
that Play page. Expected, not a fault.

### Legacy route: Firebase App Distribution
1. On the Android phone, open the email from **Firebase App Distribution** /
   **"SnowServ"** (check spam; use the newest one).
2. Tap **Get started** / **Accept invitation**.
3. Sign in with the Google account the invite went to.
4. It prompts to install **Firebase App Tester** from the Play Store → install it.
5. Open **Firebase App Tester** → **SnowServ** → **Download** / **Install**
   (allow "install unknown apps" if asked — normal for test builds).
6. SnowServ (snowflake icon) is now on the home screen.

## PART 2 — Sign up as a customer
1. Open **SnowServ** → **Don't have an account? Sign Up**.
2. Keep **Customer** selected; fill name, phone, email, password (6+ chars) → **Sign Up**.
3. **Check email and click the confirmation link** (required).
4. Back in the app → log in with email + password (no Customer/Provider tab).

## PART 3 — Place a test order (the thing we're verifying)
1. **Add address** → type the Yonkers address you were given (not his own).
2. Pick **Driveway Only** (~$120).
3. **Choose "Large"** when asked the driveway size  ← the key new step.
4. Optional: toggle **Add Deicer**. Note the storm-pricing line.
5. **Request Service** → on the Stripe page pay with **4242 4242 4242 4242**,
   any future expiry, any CVC.
6. Order should appear as active on the home screen.

## PART 4 — Set up a PROVIDER test account (Tony, Android)

Not needed until we actually test the provider side — none of this expires, and the
Stripe account isn't created until he taps "Set up payouts". Requires build 17+.

**Use fake data throughout.** Tony is not going to be a real provider (decided with
Vince 2026-08-07), so real personal details would only be data we'd have to remember
to scrub later. Name it obviously so it's still identifiable as a test row in
November, when the provider list has real people in it.

Registration is 4 steps — Equipment · Insurance · Payouts · Agreement. There is NO
identity step and no ID upload; Stripe verifies identity during payout onboarding.

| Field | Value |
|---|---|
| Name | `Test Provider (Tony)` |
| Phone | `555-555-0101` (555-01xx is reserved for fiction, can't reach anyone) |
| Equipment | **Plow truck** — exercises the truck fields and driveway dispatch |
| Truck | any make/model/year, plate `TEST123` |
| Insurance carrier | `Test Insurance Co` |
| Policy | `TEST-0001`, any future expiry, photo of any piece of paper |

**Stripe payout onboarding — TEST MODE values** (no real bank, no real SSN):

| Field | Value |
|---|---|
| Date of birth | `01/01/1901` — Stripe's always-passes value |
| SSN | `000-00-0000` (or `0000` if only the last four is asked) |
| Routing number | `110000000` |
| Account number | `000123456789` |
| Address / phone | anything plausible; test mode doesn't check |

Stripe usually also offers a test-mode shortcut to auto-fill the form.

**Why he must do this at all:** going online is gated on `payouts_enabled` (2026-08-07).
batch-payouts already skipped anyone without it, so before that gate a provider could
work a whole storm and silently never be paid. Tony can't accept a job until Stripe
says payouts are live.

**None of this survives go-live.** Stripe keeps test and live accounts completely
separate, so Tony's connected account simply won't exist once we swap in live keys —
nothing to clean up on that side. ⚠️ But our SUPABASE rows are NOT test/live split:
every test provider and customer is still there on launch day. See PRELAUNCH.

## What to report back
- Did the Stripe payment page load and complete? (the emulator couldn't)
- Screenshot of the order screen showing the Small/Large choice
- Anything confusing or broken

## Admin-side verification (Vince/Claude, after he orders)
Query jobs for driveway_size on the new job:
  select id, job_number, service_type, driveway_size, status, final_price
  from jobs order by created_at desc limit 5;
Expect driveway_size='large' on his order. Also confirm the job appears in the admin
panel and dispatches.
