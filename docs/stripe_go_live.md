# Stripe go-live runbook

**Status:** not started. Written 2026-09-05, to be executed in one focused session.

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
   Also turn on **1099-NEC filing**. Account-level config, not code.
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

## 2. Verification — do not skip

1. **One real order with a real card** to a Yonkers address. Confirm: job row
   created, `payment_intent_id` set, status `requested`.
2. **Refund it** from the admin panel. Confirm the hold releases.
3. **Isaiah onboards payouts** on the live account. Confirm `payouts_enabled`
   flips true and he can toggle Online.
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
