# NY Certificate of Authority (Sales Tax) — Application Answers

**Status:** Answers finalized 2026-07-25. NOT yet submitted — NY Business Express
blocks submission until **90 days before the business begin date**.

## When to submit
- Business begin date entered: **November 15, 2026**
- 90-day application window opens: **~August 17, 2026**
- **Plan: submit early-to-mid September 2026** (inside the window, late enough to
  avoid empty $0 sales-tax returns before the season generates revenue).

## Where
NY Business Express — https://www.businessexpress.ny.gov (log in with the NY.gov ID).
Check the dashboard first for a saved/in-progress draft before re-entering.

## Answers (as entered)
- **Entity type:** LLC (member-managed, domestic NY LLC)
- **NAICS code:** 561730 — Landscaping Services
- **Home-based business:** Yes
- **Member information:** Vince Citarella — sole member, 100% ownership
- **Business / mailing address:** _[fill from the LLC filing — same as on file]_

## Business-activities description (the field that kept erroring)
The field rejects invisible characters from copy-paste (non-breaking spaces). **TYPE
it by hand** — do not paste. Only letters, spaces, commas, periods. Max 200 chars.

> Snow removal services. We shovel and plow driveways, walkways and sidewalks, and
> apply salt. Customers book and pay through our mobile app.

## After it's approved
- Add the NY sales-tax registration inside **Stripe Tax** (Stripe → Tax → Registrations).
  Until a registration exists, Stripe Tax calculates **$0** and the checkout is unchanged.
- The sales-tax code (create-checkout-session + stripe-webhook `tax_amount`) is already
  written and staged in the repo; it stays inert until that registration is live.
