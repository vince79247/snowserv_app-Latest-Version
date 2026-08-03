# Equipment Financing / "SnowServ Financial" — Strategy Memo

**Status:** IDEA ONLY. Nothing built, nothing committed to. Written 2026-08-03 at
Vince's request to think the thing through before it gets built.

**Short version:** the instinct is right — equipment is the real supply constraint,
and financing it is the strongest retention lever available to a marketplace like
this. But three of the four ways to do it attack the independent-contractor
posture that the entire company is built on, and one of them costs nothing and
carries no risk at all. Do the free one now. Revisit the rest in Year 2 with data.

---

## 1. Why the idea is genuinely good

**Equipment is the binding constraint on supply quality, and the code already
knows it.** `dispatch_jobs()` pushes a shovel-only provider last for a large
driveway. The admin storm-readiness panel counts `bigJobCapable` (`equipment !=
'shovel'`) as its own number precisely because a warm body with a shovel is not
interchangeable with one who owns a plow. Recruiting ten shovel providers does
not solve the same problem as recruiting two plow providers.

A prospective provider who wants in but owns nothing is not a bad provider — they
are a capital problem. A snowblower is roughly $700–1,500; a plow setup is several
thousand plus a truck that can carry it. That is a real barrier for exactly the
person most motivated to work.

**The retention argument is stronger than the recruiting one.** The Provider
Service Agreement polices customer-harvesting with a Non-Circumvention clause —
a *contractual* deterrent, which means it works only as far as you are willing to
sue a guy over a $125 driveway. You never will. A provider who is paying off a
snowblower through SnowServ has an *economic* reason to keep the app open, and
economic reasons enforce themselves. That is the actual prize here: it converts
an unenforceable clause into a structural one.

**The plumbing already exists.** `process-payout` / `batch-payouts` already
compute a provider's cut and transfer it. Withholding a lease payment from the
75% before transfer is a small change, not a new system.

So: correct instinct. The problems are not with the logic.

---

## 2. The problem — it points a gun at the contractor classification

On 2026-08-01 the NAICS code was deliberately changed to **513210 Software
Publishers**, and `docs/ny_certificate_of_authority.md` states the reasoning
plainly: *"SnowServ owns no equipment, employs no crews and performs no physical
labor."* That sentence is load-bearing. It is why the providers are 1099, why
there is no FICA exposure, and why the insurance can be written as software E&O
rather than landscaping GL.

Furnishing equipment cuts directly against it. Under the IRS common-law test,
**who supplies the tools and equipment** is an explicit factor in the "financial
control" prong, and so is whether the worker has an unreimbursed investment in
their own facilities. NY's tests look at the same substance. A structure where
SnowServ buys the snowblower, hands it to the worker, tells them (through
dispatch) where to go, and deducts the payment from their pay is a structure that
reads as employment to anyone whose job it is to find employment.

Vince has already said plainly that he does not want the contractor classification
questioned. This idea is the single largest threat to it currently on the table —
larger than anything in the dispatch or pricing code.

**Two consequences worth stating separately:**

- **Deducting from pay.** If providers were ever reclassified, NY Labor Law §193
  sharply restricts what may be deducted from an employee's wages, and equipment
  costs are not on the friendly side of that line. A deduction program is
  therefore not just a symptom of reclassification risk — it is evidence *for* it,
  handed over pre-assembled.
- **Lending is a licensed activity.** Financing a *business* is treated far more
  leniently than lending to a *consumer*, and a provider operating as a sole
  proprietor sits uncomfortably between the two. NY also has a criminal usury
  ceiling. None of this is fatal; all of it is a lawyer and a license, not a
  weekend.

**White-labeling helps with exactly one of these.** Putting a real lender behind
the "SnowServ Financial" brand moves the *licensing* problem onto someone who
already solved it. It does **not** move the classification problem, because that
question is about the economic substance of the relationship, not about whose name
is on the note — unless SnowServ genuinely stays out of it (see Option A).

---

## 3. The four structures, cheapest to most dangerous

### Option A — Buying group / dealer discount ✅ *do this one*
Negotiate fleet or contractor pricing with a local dealer (Toro, Ariens, a Home
Depot Pro account) and pass it to providers. They buy with their own money and
their own credit. SnowServ never lends, never owns, never deducts.

- Capital required: **$0**
- Licensing: **none**
- Classification risk: **none** — a discount is not control, and the provider's
  unreimbursed investment in their own tools actually *strengthens* the
  contractor posture
- Value to provider: real, immediate
- Recruiting value: it is a concrete line for the "Plow with us" form *today* —
  "contractor pricing on equipment" beats another sentence about flexible hours

The downside is that it creates no lock-in. That is fine. Lock-in is a Year-2
problem; supply is a this-winter problem.

### Option B — Pure referral to a third-party lender
Point providers at an equipment lender or dealer financing. Optionally take a
referral fee. SnowServ never touches the note or the payments.

- Preserves 1099 **provided SnowServ does not deduct, guarantee, or select the
  equipment.** The moment repayment runs through the payout pipeline, this
  collapses into Option C.
- Modest upside, near-zero risk. Reasonable second step after A.

### Option C — Partner lends, SnowServ deducts and remits ⚠️
The lender holds the paper; SnowServ withholds from the 75% and forwards it. This
is what most people mean by "SnowServ Financial."

- This is where classification risk returns in full, and it adds a role nobody
  wants: **SnowServ becomes the collections agent.** When a provider has a bad
  month, the app is what took their money. That is a miserable relationship to
  have with your own supply.
- Requires counsel, a real partner agreement, and probably a written provider
  authorization for the deduction.

### Option D — SnowServ owns the equipment and leases it ❌
Maximum lock-in, and maximum everything else: capital tied up in depreciating
metal, licensing exposure, default and repossession (you now own a snowblower
somewhere in Yonkers belonging to someone who stopped answering), and the
strongest possible argument that these people are employees.

A pre-revenue company with one payable provider should not be operating a
finance book.

---

## 4. Recommendation

1. **Now (free):** pursue Option A. One conversation with a dealer. Add the
   benefit to the provider recruiting copy and the interest form.
2. **Now (free):** instrument the decision. Provider registration and the leads
   pipeline already capture `equipment`. Start counting: how many leads arrive
   shovel-only, and how many jobs get routed past someone because of it. That
   number is the entire business case, and right now nobody knows it.
3. **Year 2, only if the data says so:** revisit B, then possibly C — with an
   attorney reviewing classification *before* any deduction is written.
4. **Probably never:** D.

## 5. What would have to be true before building anything beyond A

- A meaningful count of providers turned away or underused for lack of equipment
  (not anecdotes — the number from step 2).
- Provider lifetime value comfortably exceeding cost of capital plus default rate,
  measured on real retention data that does not exist yet.
- Written counsel sign-off that the structure survives IRS and NY DOL scrutiny.
- Enough operating cash that a defaulted lease is an annoyance, not an event.

## 6. Naming note

"SnowServ Financial" is a good brand and a bad name to use early. Naming a
non-lending entity "Financial" invites the assumption that it lends, and some
states restrict finance-suggestive names in entity filings. If Option A or B is
what actually happens, call it what it is — "SnowServ Provider Equipment
Program" — and hold the better name until there is something behind it.

---

**Open questions for counsel (not for me):**
- Does a payout deduction for a third-party lease, by itself, move the needle on
  contractor classification in NY?
- Does financing a sole proprietor with no LLC count as commercial or consumer
  credit?
- Does any of this affect the E&O/GL policy being bought this winter?
