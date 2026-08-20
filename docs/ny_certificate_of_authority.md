# NY Certificate of Authority (Sales Tax) — Application Answers

## ✅ SUBMITTED 2026-08-20, 06:34 AM

| | |
|---|---|
| Entity name | SnowServ LLC |
| **Application ID** | **DTF17-2026-052519** |
| **Document Locator Number (DLN)** | **4604477** |
| Submitted via | NY Business Express (businessexpress.ny.gov) |
| Business begin date entered | 11/15/2026 |

Check status / print the certificate under **Recent Activity** on the Business
Express dashboard. A confirmation email was also sent.

⚠️ **First return: 2026-12-20 IF NY assigns quarterly filing — CONFIRM WHEN THE
CERTIFICATE ARRIVES.** The rule is that the first return covers the period
containing the 11/15/2026 begin date, but which period that is depends on the
filing frequency NY assigns, and they only tell you with the certificate:
- **Quarterly** → period Sep 1 – Nov 30, due **2026-12-20**.
- **Annual** → period Mar 1 2026 – Feb 28 2027, due **2027-03-20**. Genuinely
  possible here: NY allows annual filing when tax due is under $3,000/yr and
  taxable receipts are under $300,000, which is exactly what was estimated on
  the application ($0–$35,000 sales / $0–$3,000 tax).

The Dec 20 reminder on Vince's Mac is the CONSERVATIVE one — it fires first
either way. Adjust it once the assigned frequency is known. Filing is mandatory
even at zero sales; NY bills automatically for a missed return, **$50 minimum
penalty**.

Worth recording because it disproves the old plan: the application's own warning
says the first return covers the period containing the BUSINESS BEGIN DATE, not
the application date. So applying in August created **no** extra $0 returns —
the "wait until September to avoid empty filings" reasoning was solving a problem
that did not exist, and cost three months of schedule risk for nothing.

### When the certificate arrives
1. Stripe → **Tax** → **Registrations** → add New York.
2. The sales-tax code (create-checkout-session + stripe-webhook `tax_amount`) is
   already written and staged; it goes from calculating $0 to real money the
   moment that registration exists.
3. Place one test order and confirm the price SHOWN equals the price CHARGED.
4. Update `docs/snowserv_llc_operating_agreement_execution.html` §6.4 if you ever
   re-execute the agreement — it currently says the Company "shall register",
   which is accurate now and stays accurate after issuance.

---

**Original status note:** Answers finalized 2026-07-25. NY Business Express
blocked submission until **90 days before the business begin date**.

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
- **NAICS code:** **561790 — Other Services to Buildings and Dwellings**
  (settled 2026-08-20 against the Census index — see the NAICS section below.
  NOT 561730 Landscaping, NOT 513210 Software Publishers.)
- **Home-based business:** Yes
- **Member information:** **Vincent R. Citarella** — sole member, 100% ownership.
  Corrected 2026-08-20; this doc previously said "Vince Citarella". Use the LEGAL
  name exactly as it appears on the LLC formation filing — a state registration
  that does not match the entity record is a rejection, and the name has to be
  identical across the CoA, the LLC filing, the EIN and the insurance policy.
- **Business / mailing address:** _[fill from the LLC filing — same as on file]_

## ⚠️ NAICS REVERSED 2026-08-20 — use 561790, NOT 513210 and NOT 561730

Vince looked at the live record (it still reads **561730 Landscaping Services**,
so the "NY already has 513210" claim below is WRONG) and said the classification
felt off. He was right, and the fix below was also wrong. Checked against the
Census NAICS index rather than reasoning from memory:

- **561730 Landscaping Services** — snow plowing **combined with** landscaping or
  seasonal property maintenance. We do not do landscaping, so this is wrong.
- **561790 Other Services to Buildings and Dwellings** — the index entry is
  literally *"snow plowing driveways and parking lots (i.e., not combined with
  any other service)"*. **This is us.**

**Why 513210 Software Publishers is wrong**, despite the reasoning below:
1. **It fails the revenue test**, which is how NAICS actually classifies. 513210
   is for establishments that publish or sell software. SnowServ sells software to
   nobody — 100% of revenue is a 25% cut of snow-removal jobs.
2. **It now contradicts the sales-tax registration.** We register as VENDOR OF
   RECORD selling a taxable snow-removal service. Declaring "software publisher"
   on that same certificate invites the obvious question of why we are collecting
   tax on services at all. This is the inconsistency the doc warns about, created
   by the doc itself.
3. **The reasoning below overstates what NAICS does.** Insurers rate from their
   OWN class systems (ISO/NCCI), not NAICS, and a NAICS code is not evidence in a
   worker-classification dispute — the actual working relationship is. Describe
   operations honestly on the insurance application instead (see the insurance
   section below); that is what protects the policy.

**What the July reasoning got right:** "Landscaping Services" is a bad label,
because it asserts physical landscaping operations that do not exist. 561790
solves that without pretending to be a software company — it is not landscaping,
and it accurately describes selling snow removal.

**The EIN/SS-4 carries 561730.** Leave it. NAICS is statistical, 561730 and
561790 are neighbors in the same industry group, and that mismatch is trivial
next to a cross-sector one. Do not open a federal amendment over it.

---
## SUPERSEDED — original reasoning for 513210, kept for the record (2026-08-01)
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

## DECIDED 2026-08-16: register as VENDOR OF RECORD

Vince declined an accountant and asked for a decision. Register SnowServ as the
vendor — the seller of a taxable service — NOT as a marketplace provider.

**Why:**
1. **NY's marketplace-provider rules are about tangible personal property.** They
   do not cleanly reach a pure service, so "we're a marketplace, the provider is
   the seller" does not hand the collection duty to anyone workable. It would
   make every individual shoveler the vendor, each needing their own Certificate
   of Authority. That will not happen in reality.
2. **Substance beats labels.** SnowServ sets the price, holds the customer
   relationship, takes the payment, dispatches the job, and pays the provider a
   75% cut. The customer never contracts with the shoveler. On those facts the
   state will treat SnowServ as the vendor regardless of what the Terms called it.
3. **The failure modes are asymmetric, and this is the decisive reason.** Collect
   when you did not have to → the tax still reached NY on a real transaction and
   the cleanup is administrative. Fail to collect when you should have → SnowServ
   owes the tax out of its own margin on every job of the season, plus penalties
   and interest, and finds out about it long after the money was spent.

**What follows from it:**
- Tax on the FULL customer price including deicer (TB-ST-505: the whole charge for
  a taxable service is taxable, materials included). Already how the code works.
- Sourced to the SERVICE address, not the payer's billing address. Already done.
- Providers sell their labor to SnowServ **for resale**. Hand any provider who is
  a registered vendor a **Form ST-120 resale certificate** so the same work is not
  taxed twice on its way to the customer. Most providers will not be registered.
- Do not reimburse providers for sales tax on their cut.

⚠️ **The Terms had to be made consistent with this.** They said *"SnowServ is a
marketplace and payment facilitator"*, the opposite of a vendor-of-record
registration. Rewritten 2026-08-16 (website/terms.html §1) to "sells snow-removal
services and fulfills them through independent providers", plus a sales-tax
bullet in §3.

## Insurance is a SEPARATE question — do NOT copy the tax answer onto it

I first wrote "buy the policy as a seller of snow-removal services that
subcontracts the work." **That was wrong and Vince caught it** (2026-08-20). It
repeats the exact error the NAICS section above already resolved: tax duty follows
the TRANSACTION, classification follows WHAT THE BUSINESS DOES. SnowServ owns no
equipment, employs no crews and performs no labor. To an underwriter it is a
software platform / online marketplace, and describing it as a snow contractor
buys a policy priced and scoped for equipment operation that never happens — the
classic way a claim gets denied.

**But classification is not the same as exposure.** If a provider cracks a
driveway or someone slips on a walkway that was salted badly, the customer's
agreement is with SnowServ, so SnowServ gets named in the claim whether or not it
owns a shovel. So the requirement is:

1. **Tech E&O / cyber** for the platform itself (app failure, data breach).
   ⚠️ These policies routinely **exclude bodily injury and property damage** —
   which is exactly the snow-removal claim. Tech E&O alone is the trap.
2. **General liability** that does NOT exclude *"operations performed by
   independent contractors on your behalf."* Read for that exclusion specifically;
   it is common and it would void the coverage that matters most here.
3. **Require every provider to carry their own GL and name SnowServ as ADDITIONAL
   INSURED**, and collect the certificate. This is the primary defense — SnowServ's
   own policy is the backstop. Registration already collects `insurance_*`; the
   additional-insured requirement is what is missing from it.

Describe operations honestly on the application: a software platform that sells
snow-removal services to consumers and fulfills them through independent
contractors. That sentence is true, is consistent with the CoA and the Terms, and
tells the underwriter the real exposure. Concealing the fulfillment side to get a
cheaper tech policy is how a denied claim happens.

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
