# Are SnowServ's providers really independent contractors? — a determination

Written **2026-10-16** because Vince asked for an answer, not a referral.

**Bottom line up front:** Under the ordinary common-law test, SnowServ's
classification is **defensible but not clean**. Under New York's *Construction
Industry Fair Play Act* ABC test — **if that Act reaches snow removal, which is
genuinely unresolved** — SnowServ **probably fails**, on one specific prong that
cannot be fixed without becoming a different company.

The realistic near-term danger is **not an audit**. It is **one injured
shoveler**.

---

## 1. Two different tests, and which one applies is the whole ballgame

### The common-law test (workers' comp, general default)
Multi-factor, weighing direction and control. No single factor decides it. This
is the test the Workers' Compensation Board applies. **SnowServ does reasonably
well here** — see §3.

### The ABC test (Construction Industry Fair Play Act, Labor Law §861-c)
A worker is **presumed an employee** unless **ALL THREE** are true:
* **(A)** free from direction and control
* **(B)** the service is performed **outside the usual course of the employer's
  business**
* **(C)** the worker has an independently established trade or business of the
  same nature

Fail any one prong and the worker is an employee. **SnowServ fails (B)
outright** — see §4.

### So: does the Act reach snow removal?
§861-b defines construction as *"constructing, reconstructing, altering,
**maintaining**, moving, rehabilitating, repairing, renovating or demolition of
any building, structure, or **improvement**, or relating to the excavation of or
other development or **improvement to land**."*

Snow is not mentioned. No case law, DOL guidance or commentary found that
answers it. **It is an open question**, and the honest confidence level is
"unresolved," not "we're fine."

⚠️ **THE PROBLEM WE CREATED OURSELVES.** SnowServ has already told New York, in
writing, that this service **is the maintenance of real property** — that is the
basis of the sales-tax position and the Certificate of Authority
(`ny_certificate_of_authority.md`, CLAUDE.md "Sales tax"). A driveway or
sidewalk is plainly an "improvement to land." So the exact characterization that
makes the service taxable is the same characterization that hooks it into
§861-b's "maintaining... improvement to land."

Same state, two agencies, one position already on file. We cannot argue "this is
real-property maintenance" to the Tax Department and "this is not maintenance of
an improvement to land" to the Department of Labor. **Pick one and live with it
— and the tax one is already filed.**

---

## 2. What SnowServ actually does to providers (the facts any test runs on)

| Factor | Points to | Why |
|---|---|---|
| Uses own equipment (shovel/blower/truck) | **contractor** | Classic, strong |
| Sets own hours via the online toggle | **contractor** | No schedule imposed |
| Can reject any job, no penalty | **contractor** | Real autonomy |
| Non-exclusive; may work for anyone | **contractor** | Strong |
| No uniform, no training, no supervisor | **contractor** | |
| Paid per job, 1099-NEC via Stripe | **contractor** | |
| **SnowServ sets the price unilaterally** | **EMPLOYEE** | The single worst factor |
| Dispatch algorithm assigns the job | **EMPLOYEE** | Work is directed, not bid |
| Completion photo **required** | employee-ish | Prescribes how work is proven |
| GPS captured at start and complete | employee-ish | Monitoring |
| Rating system; admin can suspend | employee-ish | Discipline analog |
| Non-circumvention clause in the agreement | employee-ish | Restricts their business |

Control indicia are heavier than they look. The photo, the GPS and the rating
system are each individually defensible, but together they read as supervision.

---

## 3. Under the common-law test: DEFENSIBLE
The strong contractor factors — own equipment, own hours, free rejection,
non-exclusivity — are the ones the WC Board weighs most heavily for manual
trades. Price-setting and monitoring cut the other way but are not fatal on
their own. **Call it defensible, not safe.**

## 4. Under the ABC test: PROBABLY FAILS, on prong (B)
Prong (B) asks whether the work is outside SnowServ's usual course of business.

**SnowServ's usual course of business IS selling snow removal.** It sets the
price, holds the customer, takes the payment, and is the **vendor of record**.
The providers perform the precise service SnowServ sells. There is no reading in
which snow removal is "outside the usual course of business" of a company whose
entire business is snow removal.

This is the same prong that defeated the ride-hail and delivery platforms in the
California fights. It cannot be drafted around, and it cannot be fixed by
changing the agreement. The only cure is not being the seller — which would
unwind the vendor-of-record decision, the Terms, and the tax registration.

Prong (A) is arguable. Prong (C) is weak — a person who signed up on an app with
a shovel is usually not an independently established business of the same nature.

---

## 5. The realistic trigger is an INJURY, not an audit

With 7 providers and no revenue, audit risk is low today and rises with scale.
But classification is almost never tested by an auditor knocking. It is tested
when:
* **a provider is injured and files a workers' comp claim** ← the likely one
* a provider files for unemployment after being deactivated
* a provider sues over pay

Shoveling snow is genuinely hazardous — back injuries, falls, and cardiac events
are the known profile. Over a season, with people over 40 doing heavy manual
labor in cold weather, this is not a remote scenario.

⚠️ **New York penalties for failing to secure workers' compensation are severe
and can reach the business owner personally.** That is the real downside tail,
and it is much worse than the misclassification finding itself.

---

## 6. What to actually do, ranked by value

1. **Resolve workers' comp with the broker — this is the single highest-value
   action.** Either a policy, or a properly filed **CE-200** exemption. If a
   provider is hurt and coverage responds, the claim is paid and the
   classification fight may never happen. If there is no coverage and the Board
   deems them an employee, you are uninsured for a claim you are liable for.
   It is question 6 of the broker email for exactly this reason.
2. **Require providers to carry their own WC or file a CE-200**, once supply can
   bear it. Same tiering logic as GL.
3. **Write the good facts into the Provider Service Agreement explicitly** —
   that the provider supplies their own equipment, sets their own hours, may
   decline any job without penalty, and may work for competitors including
   during the term. These are already true; making them express helps under the
   common-law test and costs nothing. ⚠️ Editing the agreement forces every
   signed provider to re-accept, so bundle it with any other change.
4. **Consider letting providers adjust price within a band.** This directly
   attacks the worst factor. It also changes the product, so it is a real
   business decision, not a compliance tweak. Not recommended now.
5. **Do NOT** write to `dol.misclassified@labor.ny.gov` naming SnowServ to ask
   whether we are compliant. That address is the misclassification *complaint*
   channel. A general question about whether snow removal is "construction"
   under §861-b can be asked without identifying the business.

---

## 7. What this document is not

This is a reasoned determination on the facts in this repo. What it cannot give
you is attorney-client **privilege** (this file is discoverable and the repo is
public), a **malpractice carrier** standing behind the answer, or knowledge of
how the WC Board actually decides these in practice as opposed to what the
statute says. Those three things are what the money buys — not intelligence.

The one question genuinely worth paying for: **does the Construction Industry
Fair Play Act reach residential snow removal?** Everything above turns on it,
and no public authority answers it.

⚠️ This file is in a PUBLIC repo. Say nothing here that would be unhelpful to
read back in a hearing. It is written to be accurate, not to be favorable.
