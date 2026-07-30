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
