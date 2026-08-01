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
- **NAICS code:** **513210 — Software Publishers** (corrected 2026-08-01; was
  561730 Landscaping Services, which was wrong on the earlier EIN/state paperwork)
- **Home-based business:** Yes
- **Member information:** Vince Citarella — sole member, 100% ownership
- **Business / mailing address:** _[fill from the LLC filing — same as on file]_

## NAICS code — why 513210, not 561730 (decided 2026-08-01)
The earlier filings (EIN / SS-4 and NY paperwork) used **561730 Landscaping
Services**, which covers snow plowing. That was wrong, and 513210 is what NY now
has on file. Keep 513210 everywhere from here.

**Why 513210 is right:**
1. It describes what the business actually DOES. SnowServ owns no equipment,
   employs no crews and performs no physical labor. It builds and operates
   software. A landscaping code asserts physical operations that do not exist.
2. It protects the contractor structure. Being classified as a landscaper cuts
   against the whole legal posture of the Provider Service Agreement — that
   providers are independent contractors, not SnowServ crews. Don't hand anyone a
   document where SnowServ calls itself a landscaping company.
3. It matters most for INSURANCE. A GL/E&O policy written against a landscaping
   classification is priced and scoped for equipment operation SnowServ never
   does — the classic way a claim gets denied. Get this right before buying any
   policy this winter.
4. NY already has 513210. Aligning the federal code to the state one is cleaner
   than creating a state/federal mismatch to fix a mismatch.

**The apparent contradiction, resolved:** "I'm a software company" and "I collect
NY sales tax on snow removal" are not in conflict. Sales-tax obligation follows
the TRANSACTION, not the filer's industry code. A platform that is the seller of
record for a taxable service collects tax on it regardless of being classified as
software. The NAICS code is statistical; the tax duty is transactional.

⚠️ **The one thing to confirm with the accountant** — this changes HOW to
register, not the NAICS code: is SnowServ registering as the **vendor of record**
(selling snow removal and subcontracting it) or as a **marketplace provider**
(facilitating providers' sales)? NY's marketplace-provider rules were written
mainly around tangible goods, so their application to SERVICES needs checking.
It affects who owes the tax, what goes on the return, and what the Terms should
say — and the answer must be consistent across the CoA, the tax return, the
insurance application and the Terms of Service. Inconsistency between those four
is what draws scrutiny.

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
