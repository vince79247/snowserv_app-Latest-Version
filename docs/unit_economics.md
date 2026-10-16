# SnowServ unit economics — what percentage is actually his

Built **2026-10-16** from LIVE database values, not from the numbers in CLAUDE.md
(those are a snapshot and drift). Re-run the model if prices or commission change.

**Inputs, read from the DB on 2026-10-16:**
Yonkers — sidewalk $80 · driveway $120 · both $160 · deicer 45/70/90 ·
`commission_pct` = 25 · storm bands 1.0 / 1.2 / 1.5 / 2.0x.
Sales tax 8.875% (Yonkers combined), currently calculating $0 until the Stripe
Tax registration is added — modelled here as live, because it will be.

---

## 1. The headline

| Measure | Result |
|---|---|
| Of every dollar a customer spends | **~21¢ is SnowServ's**, before fixed costs and insurance |
| Of the stated 25% commission | **~84% survives payment processing** |
| Net margin on revenue, 250+ jobs, no WC | 67–80% |
| Net margin on revenue, 250+ jobs, WC at $8/$100 | **43–56%** |
| Net margin on revenue, 250+ jobs, WC at $15/$100 | 22–35% |
| Breakeven on software alone | **13 jobs/season** |
| Breakeven once insurance is carried | **~80–120 jobs/season** |

## 2. Per-job, at live Yonkers prices

| Service | Customer pays | Provider | NY tax | Stripe | Gross com | **NET** | % of com | % of job |
|---|---|---|---|---|---|---|---|---|
| Sidewalk | $87.10 | $60.00 | $7.10 | $3.26 | $20.00 | **$16.74** | 83.7% | 20.9% |
| Driveway | $130.65 | $90.00 | $10.65 | $4.74 | $30.00 | **$25.26** | 84.2% | 21.0% |
| Both | $174.20 | $120.00 | $14.20 | $6.22 | $40.00 | **$33.78** | 84.4% | 21.1% |
| Both + deicer | $272.19 | $187.50 | $22.19 | $9.55 | $62.50 | **$52.95** | 84.7% | 21.2% |

**The margin is flat.** ~84% of commission on every service, and storm surge does
not change it (1.0x → 84.4%, 2.0x → 84.8%) because the only fixed element is
Stripe's 30¢. Surge raises dollars, not percentage.

Variable costs modelled: Stripe 2.9% + $0.30, Stripe Tax 0.5%. ⚠️ Both are
charged on the FULL amount including sales tax, and on the full job value —
SnowServ pays processing on the 75% it hands straight to the provider.

## 3. Fixed costs are not the problem

| | Annual |
|---|---|
| Apple Developer | $99 |
| Supabase Pro (once off free tier) | $300 |
| Zoho Mail Lite · Cloudflare domain | $29 |
| Firebase Hosting · Resend (free tiers) | $0 |
| **Total** | **~$453** |

**13 jobs pays for the entire software stack for a year.** Anyone worrying about
SaaS subscriptions here is looking at the wrong line.

## 4. ⚠️ WORKERS' COMP IS THE WHOLE BALLGAME

WC is rated on **payroll**, and per `insurance.md` §7 the provider payout IS the
payroll — every provider is an uninsured individual, so 100% of their pay counts.

Payroll = 75% of GMV. So:

| WC rate | Cost as % of job value | Share of SnowServ's contribution it consumes |
|---|---|---|
| $8 per $100 | 6.0% | **28%** |
| $15 per $100 | 11.2% | **53%** |

**This is larger than every other cost except the provider payout itself —
bigger than Stripe, and an order of magnitude bigger than all software combined.**

### Net profit by volume (avg job $160, GL assumed $1,200 minimum)

| Jobs/season | GMV | Commission | No WC | WC @ $8 | WC @ $15 |
|---|---|---|---|---|---|
| 50 | $8,000 | $2,000 | $6 (0%) | **−$474** | **−$894** |
| 100 | $16,000 | $4,000 | $1,695 (42%) | $735 (18%) | −$105 (−3%) |
| 250 | $40,000 | $10,000 | $6,731 (67%) | $4,331 (43%) | $2,231 (22%) |
| 500 | $80,000 | $20,000 | $15,116 (76%) | $10,316 (52%) | $6,116 (31%) |
| 1,000 | $160,000 | $40,000 | $31,874 (80%) | $22,274 (56%) | $13,874 (35%) |

**At 50 jobs with insurance, the season loses money.** The first ~100 jobs pay
for the insurance, not for Vince.

### The lever
Rule VIII removes a provider's pay from payroll if their own certificate of
coverage is produced. **Every insured provider is a direct, dollar-for-dollar
premium reduction** — not just liability protection. This is the strongest
argument for pushing COIs hard, and for tiering by equipment (a plow operator is
the biggest payroll line AND the highest rate).

## 5. Smaller leaks worth knowing

* **Sales tax costs him $0.48 per $160 job in Stripe fees — 1.2% of commission —
  on money he never keeps.** The price of being vendor of record. Unavoidable.
* **A cancellation AFTER capture is a pure loss.** Stripe keeps its processing fee
  on a refund. Releasing an uncaptured hold is free, which is why capture-on-start
  matters financially, not just ethically.
* **Connect Express is ~$2/month per provider who receives a payout.** Trivial at
  volume; noticeable if many providers do one job a season.

## 6. ⚠️ NOT IN THIS MODEL

* **Customer acquisition cost.** Nothing here. Door hangers were quoted at ~$2,000
  for 10,000 (`project-door-hangers`). At $33.78 contribution per job, that print
  run must produce **60 jobs just to break even.** CAC is likely the second-largest
  cost line after insurance and is entirely unmeasured.
* Chargebacks and disputes ($15 Stripe dispute fee each).
* Any wage for Vince. All "net" figures above are pre-owner-compensation.
* Accounting, the $50 LLC publication filing, the biennial statement.

## 7. Numbers to confirm before trusting this
| Assumption | Status |
|---|---|
| Stripe 2.9% + $0.30 | standard US card rate, high confidence |
| Stripe Tax 0.5%/txn | **confirm on the Stripe pricing page** |
| Connect Express $2/MAU | **confirm** |
| GL minimum $1,200 | **illustrative — ask Careene** |
| WC rate per $100 | **UNKNOWN and it decides everything — ask Careene for the class code and rate** |
| Avg job $160 | assumed "both"; a sidewalk-heavy mix lowers dollars, not percentages |
