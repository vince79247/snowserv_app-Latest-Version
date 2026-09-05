# Stripe go-live runbook

**Status: HALF DONE — paused 2026-09-05 evening, resuming when Vince is back.**

### ✅ Done 2026-09-05
- Live webhook endpoint created: **"SnowServ production — creates jobs"**,
  destination `we_1UCDF9BYwOCAVVcUkY5RSJxO`, listening to
  `checkout.session.completed` only, API version 2026-05-27.dahlia, pointed at
  `.../functions/v1/stripe-webhook`.
- **`STRIPE_WEBHOOK_SECRET` swapped** to that endpoint's new `whsec_`.
- **`STRIPE_SECRET_KEY` swapped** to the live `sk_live_`.

### ⚠️ THEREFORE: TEST MODE IS DEAD AS OF NOW
Card `4242 4242 4242 4242` no longer works. The `claude.test.*` accounts cannot
transact. Every payment test from here is a real card. (Orders are an
authorization HOLD, not a charge — capture only happens when a provider taps
Start — so a test order + cancel moves no money.)

### ❌ Still to do
- Payouts → **MANUAL** (step 5)
- **Live NY tax registration**, start 11/15/2026 (step 6)
- **Clear the two dead test Connect rows** (step 1b)
- **All verification** (§2) — nothing has been tested on live keys yet

### ⚠️ UNCONFIRMED: is the Yonkers zone off?
Asked repeatedly on 2026-09-05, never confirmed. **Check this first.** With the
zone on and zero providers, a real customer can now place a real hold on a real
card and have nobody ever come. (Before the key swap the failure was a declined
card; now it is a stranded order, which is worse for the customer.)

### Note for whoever resumes
Stripe's Workbench UI has **no "Send test event"** on a destination — the ⋯ menu
offers only Disable / Roll secret / Delete. Do not go looking for it. Verify with
a real order instead (§2), which proves more anyway.
⚠️ Never click **Roll secret** — it invalidates the `whsec_` now in Supabase.

---

Written 2026-09-05, to be executed in one focused session.

**Why this has to happen before recruiting, not after.** The provider path is what
breaks in test mode, and recruiting is what drives people down it. With the test
key in place, `connect-onboard` creates a **test-mode** Connect account, stores a
dead `acct_...` on the provider row, and can set `payouts_enabled = true` — which
is the flag gating "go online". A provider would be told they are set up, be
allowed to accept a job, and be unpayable. Vince caught this: the approval email
and the in-app banner have been pointing providers at exactly that.

⚠️ **Switching kills test mode.** One Supabase project, one `STRIPE_SECRET_KEY`.
After the swap, card `4242 4242 4242 4242` stops working and the `claude.test.*`
accounts cannot transact. Every payment test costs a real charge and a refund.
That is the accepted cost of having the provider path work.

---

## ⚠️ THERE ARE TWO STRIPE ACCOUNTS — use the right one

| Account | What it is |
|---|---|
| **`acct_1TlZBgBYwOCAVVcU`** | **THE REAL ONE.** Live + its test mode. The app uses this — the publishable key in CLAUDE.md is `pk_test_51TlZBg…`, same prefix. Everything below happens here. |
| `acct_1Tp4MgPc5sz7KTOn` | "SnowServ sandbox" — a separate, empty account. Connect was never set up in it. Ignore it. |

Stripe's account switcher lists "Test mode" and "SnowServ sandbox" side by side
and they look interchangeable. They are not. Configuring a webhook or a tax
registration in the sandbox would appear to succeed and change nothing about the
live app — the exact silent-success failure this project keeps hitting.
Check the `acct_` in the URL before changing anything.

## 0. Before you start — reconnaissance (do this first)

| Check | Where | Why it matters |
|---|---|---|
| Is the account **activated for live payments**? | dashboard.stripe.com — look for an "Activate your account" banner | Everything below is pointless until it is. This is the longest step if incomplete. |
| Any **test-mode Connect accounts**? | Test dashboard → Connect → Connected accounts | If a provider already onboarded in test, they have a dead account and possibly `payouts_enabled=true`. Clean it before the switch, not after. |
| Is the **Yonkers zone** off? | Admin panel → Areas | The app is publicly downloadable. With the zone on and Stripe in test, a real customer's real card is DECLINED. Zone off gives them "Not available in your area yet" + the waitlist instead. |

---

## 1. The switch, in this order

Order matters. Doing 2 before 3 means payments are taken with no webhook to
create jobs — money in, nothing to show for it, and the customer sees nothing.

1. **Complete the Connect platform profile** (live mode) and enable **Express**.
   ✅ Verified already done 2026-09-05 — no "finish your profile" prompt, Connect
   overview loads, zero live connected accounts.
   ⚠️ **1099-NEC filing CANNOT be turned on yet.** Connect → Tax forms says *"No US
   connected accounts — to use Connect tax forms you must have connected accounts
   located in the United States."* Stripe gates the whole 1099 configuration
   behind having at least one live connected account.
   **So it moves to after Isaiah onboards** — see step 2.3a. The window is
   between his onboarding and the first payout, and it is easy to miss because
   nothing prompts you.
2. **Register the live webhook endpoint** — Stripe → Developers → Webhooks →
   Add endpoint, live mode, event `checkout.session.completed`, pointed at
   `https://swttuujhcgpcsrxgupzv.supabase.co/functions/v1/stripe-webhook`.
   Copy its **new** `whsec_`.
   ⚠️ Live and test signing secrets are DIFFERENT. This is the single most
   dangerous step to skip — payments succeed and no job is ever created.
3. **Set `STRIPE_WEBHOOK_SECRET`** in Supabase → Project Settings → Edge
   Functions → Secrets to that new value.
4. **Set `STRIPE_SECRET_KEY`** to the live key (`sk_live_...`) in the same place.
   Do this AFTER the webhook secret, never before.
5. **Set platform payouts to MANUAL** — Stripe → Settings → Payouts. Prevents
   Stripe sweeping the balance before provider transfers clear.
6. **Add the live NY tax registration** — Tax → Locations → New York, start date
   **11/15/2026**, sales tax ID = the EIN (9 digits, NO dash). Test-mode
   registrations do NOT carry over.
   Confirm the "Confirm your tax rates" screen does NOT show 0% / exempt — the
   preset product category must be **Landscaping**, not "General - Services".

## 1b. Clear the dead test Connect IDs

Reconnaissance 2026-09-05 found **two** test-mode connected accounts, both OURS:
`alfonsocitarella1@yahoo.com` (Alfonso, flagged `users.is_test`) and "A c" — the
July/August payout verification, which is where the $90 volume on each comes
from. **No real provider onboarded into the sandbox**; Isaiah is not among them,
so nobody has to redo anything.

But after the switch their `providers.stripe_connect_id` values point at test
accounts that live mode does not know, while `payouts_enabled` may still read
true — a row that claims it can be paid and cannot. Null both columns on those
rows during the switch so nothing reports a false "payouts ready":

```sql
UPDATE providers SET stripe_connect_id = NULL, payouts_enabled = false
WHERE user_id IN (SELECT id FROM users WHERE is_test);
```

Harmless today because the readiness counts already exclude `is_test`, but it
removes a stale claim rather than leaving one lying around.

## 2. Verification — do not skip

1. **One real order with a real card** to a Yonkers address. Confirm: job row
   created, `payment_intent_id` set, status `requested`.
2. **Refund it** from the admin panel. Confirm the hold releases.
3. **Isaiah onboards payouts** on the live account. Confirm `payouts_enabled`
   flips true and he can toggle Online.
3a. **NOW turn on 1099-NEC filing** — Connect → Tax forms. It only becomes
    configurable once a live connected account exists, which is why it could not
    be done in step 1. Confirm Stripe files on your behalf and that the filer
    details read **SnowServ LLC** with the EIN and an address matching the other
    filings.
    ⚠️ Must happen BEFORE the first payout. Stripe needs to track contractor
    payments from the first dollar, and providers consent to electronic delivery
    during onboarding. Nothing prompts you to do this — it is silent until
    January, when it is too late.
    Context: providers are independent contractors and SnowServ holds no TINs by
    design (2026-08-07 — no identity documents), so Stripe is the only party that
    CAN file these.
4. Only then **turn the Yonkers zone back on**.

## 3. What is already proven and needs no re-testing
- Sales tax end to end: 8.875% Yonkers rate, $14.20 on $160, provider's $120
  untouched (verified in test 2026-08-21). Only the registration is per-mode.
- The tax product code `txcd_20070007` in create-checkout-session, and the
  account preset category Landscaping in BOTH modes.
- `ITSAppUsesNonExemptEncryption=false`, so no export compliance prompt.

## 4. After the switch
- Every provider onboards ONCE, on live. No redo.
- The in-season approval email ("The last thing to do is add your bank
  information" + a **Set up your payouts** button) becomes correct. It starts
  firing when `inSnowSeason()` flips in November — which is why this must be done
  before then regardless.
