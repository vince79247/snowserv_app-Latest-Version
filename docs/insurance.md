# SnowServ Insurance — what to buy, what to ask, what to avoid

Opened **2026-10-16**. Vince: *"we need to start exploring insurance options."*

**Current state: ZERO coverage anywhere in the chain.**
* SnowServ carries no policy of any kind.
* 7 approved providers, **not one** carries insurance (5 shovel, 2 snowblower,
  0 plow, 0 vehicles).
* Registration makes insurance OPTIONAL — "strongly recommended" — and the
  applicant just acknowledges a notice.
* Snow is ~3 weeks out.

⚠️ **Why this lands on SnowServ and not only on the provider:** SnowServ is the
**vendor of record**. It sets the price, holds the customer, takes the payment
and dispatches. The customer's agreement is with SnowServ. If somebody slips on
a badly salted walkway, SnowServ is named in the claim whether or not it owns a
shovel. "They're independent contractors" is not a shield against being sued; it
is an argument made *after* you have already been named.

---

## 1. What to buy — THREE things, not one

### a) Commercial General Liability (GL) — the one that matters
Covers bodily injury and property damage arising from the work.

⚠️ **THE EXCLUSION TO HUNT FOR:** *"operations performed by independent
contractors on your behalf."* This exclusion is COMMON and it would void exactly
the coverage SnowServ needs, since 100% of the work is performed by independent
contractors. Ask for it in writing: **"Does this policy cover bodily injury and
property damage arising from work performed by independent contractors on our
behalf? Show me where."**

A policy without that answer in writing is worthless for this business.

### b) Tech E&O / Cyber — for the platform itself
App failure, a botched dispatch, a data breach of customer addresses and cards.

⚠️ **TECH E&O ALONE IS THE TRAP.** These policies routinely **exclude bodily
injury and property damage** — which is the actual snow-removal claim. An agent
who hears "app company" will sell you this and you will feel insured while being
uncovered for the only thing likely to happen.

### c) Provider-side requirement — their GL naming SnowServ
Require providers to carry their own GL and name **SnowServ LLC as ADDITIONAL
INSURED**, and collect the certificate (COI). This is the PRIMARY defense;
SnowServ's own policy is the backstop. Identified 2026-08-20 in
`ny_certificate_of_authority.md`, never implemented. See §4 — it is not free.

---

## 2. How to describe the business to an underwriter

⚠️ Getting this sentence wrong is how a claim gets denied. Two opposite errors:

* **"We're a snow removal contractor"** → policy priced and scoped for equipment
  operation SnowServ never performs. Wrong product.
* **"We're a software platform"** (full stop) → conceals the fulfillment side,
  which is the real exposure. This is how a denied claim happens.

**Say this, exactly:**

> A software platform that sells snow-removal services to consumers and fulfills
> them through independent contractors.

True, consistent with the Certificate of Authority and the Terms, and it tells
the underwriter the real exposure. Do not soften it to get a cheaper quote.

Supporting facts they will ask for:
| | |
|---|---|
| Entity | SnowServ LLC, NY domestic LLC, DOS ID 7962382, formed 2026-07-09 |
| NAICS | 561790 — Other Services to Buildings and Dwellings |
| Operating area | Yonkers, NY (one zone today) |
| Revenue | Pre-revenue. 25% commission on each job. |
| Workers | 0 employees. All providers are 1099 independent contractors. |
| Work performed | Shoveling, snowblowing, salting. Driveways, walkways, sidewalks. Outdoor only — nobody enters a home. |
| Equipment owned by SnowServ | None |
| Vehicles owned by SnowServ | None |

---

## 3. Questions to ask every broker (same list, so quotes compare)

1. Does the GL cover **work performed by independent contractors on our behalf**?
   Is that exclusion present? Get it in writing.
2. Does it cover **bodily injury and property damage**, or is it E&O only?
3. What are the **limits** — per occurrence and aggregate? Is $1M/$2M standard here?
4. Can we add providers as **additional insureds**, or do they need their own
   policies naming us?
5. **Snow and ice is a known high-loss class.** Is there a snow/ice exclusion or
   sublimit? (Ask directly — slip-and-fall after plowing/salting is THE claim.)
6. What does it do about **New York Labor Law §§ 240/241** or any
   contractor-reclassification exposure?
7. **Workers' compensation:** NY can deem manual-labor contractors to be
   employees. If a shoveler is injured, what happens? Do we need a WC policy or
   a disclaimer of coverage (Form CE-200)?
8. What is excluded that we would expect to be covered?
9. Binding timeline — snow is weeks away. **How fast can this be in force?**

---

## 4. ⚠️ THE REAL TENSION — requiring provider insurance would gut supply

Shovelers do not carry commercial general liability. Requiring it is the single
fastest way to go from 7 providers to 0, and supply is already THE launch
blocker.

| Option | Effect |
|---|---|
| **A.** SnowServ carries GL covering contractor ops; providers not required | Higher premium. Supply preserved. |
| **B.** Require provider GL + additional insured, no exceptions | Cheapest for SnowServ. **Supply collapses to zero.** |
| **C.** Tiered by equipment — not required for shovel/snowblower, REQUIRED for plow | Matches actual risk. Recommended. |

**Recommendation: C**, because the exposure is not uniform:
* **shovel** — low. Uninsured is a defensible business risk.
* **snowblower** — moderate. Thrown rocks, property damage.
* **plow truck** — high, and the sleeper issue is that **NY personal auto
  policies generally EXCLUDE commercial use.** Somebody plowing for pay on a
  personal policy is likely uncovered for that activity and will discover it at
  claim time. A plow provider needs COMMERCIAL auto, which casual operators
  rarely have.

Already enforced on the approval side: Claude does not auto-approve any plow or
vehicle applicant — those go to Vince.

---

## 5. Sequence — what to do in what order

1. **Today:** call 2–3 brokers, same question list, get the business description
   right. Underwriting a marketplace is not instant and snow does not wait.
2. Prefer an **independent broker** who handles both technology and contractor
   risk over a direct-to-consumer online quote — a marketplace is not a form a
   website can price. Direct online carriers are worth one quote as a price
   floor, not as the answer.
3. Compare in §6 below. Do not pick on premium alone; pick on the §3.1 answer.
4. Once bound, revisit whether provider GL becomes mandatory for plow.
5. Update `provider_registration_screen.dart` copy and the Provider Service
   Agreement to match whatever is decided. ⚠️ Changing the agreement forces every
   signed provider to re-accept — so decide once, change once.

---

## 6. Quotes received

| Broker / carrier | Date | GL incl. contractor ops? | Snow/ice excl.? | Limits | Premium | Can bind by |
|---|---|---|---|---|---|---|
| | | | | | | |

