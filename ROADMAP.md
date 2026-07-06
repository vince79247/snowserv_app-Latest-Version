# SnowServ — Product & Business Roadmap

Strategic backlog beyond the launch-hardening list in PRELAUNCH.md. Captured from
a founder brain-dump 2026-07-06. Each item has a quick take + rough bucket:
**NOW** (decide/shape soon) · **SOON** (near-term feature) · **LATER** (post-launch
growth) · **PRO** (needs an attorney/CPA — don't guess).

## Trust & verification
- **Customer ID verification** — NOW (decision). Providers already submit ID at
  registration (DL, insurance, SSN). Requiring customer ID cuts fraud/chargebacks
  and adds accountability when sending a worker to a home — but ID friction at
  signup hurts conversion. My take: don't gate *signup* on ID; if anything, verify
  lightly (card on file already does a lot) and only escalate for high-value or
  commercial orders. Revisit if fraud shows up. Decide the bar before launch.

## Reach & platforms
- **Web app for rural areas (e.g. Delaware County, NY)** — LATER, with a caveat.
  Heads-up: a web app still needs internet, so it doesn't solve *no cell signal* —
  only offline-first or SMS/phone ordering would, and that's a big separate lift.
  What a web app *does* buy you: reach (desktop users, people who won't install an
  app, better SEO). Flutter web can reuse this codebase; main hurdle is Stripe on
  web (flutter_stripe is mobile-first — would likely need Stripe Checkout/Elements
  for the web flow). Admin web is already unblocked (flutter build web).

## Product scope
- **Commercial jobs** — LATER (decision). Commercial (lots, complexes, seasonal
  contracts) doesn't fit the fixed per-service pricing model — scope varies too
  much. If pursued, do it as a separate **"Request a quote"** flow (customer
  describes the site → you price manually / send a contract), not instant pricing.
  Probably a post-launch product line once residential is proven.

## Payments, tax & legal
- **Stripe Connect** — NOW (high priority, architectural). Today all money lands in
  one platform Stripe account and providers are paid by manual bank batches — that
  puts you in the flow of funds (money-transmitter risk) and you own 1099s
  yourself. **Stripe Connect** is the standard marketplace fix: providers onboard
  connected accounts, payments split automatically (your fee + their share), and
  Stripe handles payout compliance + 1099-Ks. Much better to adopt *before* volume.
  Strong recommend.
- **Stripe Tax / sales tax** — PRO. Whether NY taxes residential snow removal (and
  whether it's "sales tax on a service") is state-specific and genuinely uncertain —
  get a NY CPA to confirm taxability and nexus. Once the rules are known, **Stripe
  Tax** can auto-calculate and collect at checkout. Don't launch charging real money
  without settling this.
- **Apple Pay** — SOON. A payment method surfaced through Stripe; needs a merchant
  ID in the Apple Developer account + Stripe config. Moderate effort. (Already on
  the "not built" list in CLAUDE.md.)
- **Discount / promo codes** — SOON/LATER. Stripe has built-in Coupons + Promotion
  Codes; simplest path is to apply a Stripe promo code at payment rather than a
  fully custom system. Needs a code-entry field at checkout + price adjustment.
- **Form an LLC** — PRO. Single-member NY LLC + EIN before taking real money (home-
  services marketplace = real liability; sole prop exposes personal assets). Note
  NY's newspaper publication requirement — a formation service handles it. See the
  business-setup discussion; this is what fills the [Company Legal Name] slot in the
  provider agreement.

## Dispatch & provider UX
- **Accept window — is 4 min right?** — NOW (tune). A driver mid-job or mid-drive
  may not glance at their phone for a few minutes; too short = missed jobs, too long
  = customer waits. Consider making it configurable and tuning from real behavior.
  Closely tied to auto-accept below.
- **Auto-accept when on duty** — ✅ BUILT 2026-07-06 (opt-in toggle on provider home;
  auto-assigns in both dispatch paths — client + cron; load-aware still applies). Optional auto-accept would
  remove the "did I miss a job?" stress and speed up assignment. Risks: a provider
  auto-lands a job that's too far / more than they can handle. My take: offer it as
  an **opt-in toggle** ("Auto-accept jobs while online"), keep manual as the default,
  and pair it with the load-aware dispatch (auto-accept only the jobs routed to
  them). This largely dissolves the 4-minute-timer question for drivers who opt in.

## Growth & lifecycle (email, content)
- **Welcome emails (customers + providers)** — SOON. Transactional: fire on signup.
  Note Zoho's product split — **Zoho Mail** is a mailbox, not a sending platform.
  Use **Zoho ZeptoMail** (transactional API) or SMTP from an edge function for
  welcome/receipt emails; use **Zoho Campaigns** for bulk/marketing. Sync new
  signups into a Campaigns list via an edge function on signup (or a scheduled sync)
  so you can send bulk later.
- **Bulk email** — SOON. Covered by Zoho Campaigns once the contact sync exists.
- **Blog / content / SEO** — LATER. Content marketing to pull in organic customers;
  naturally lives on the web/marketing site, not in the app. Low priority vs. the
  above.

---
## Suggested sequencing (my opinion)
1. **Before real money:** LLC + sales-tax answer (both PRO), and decide the
   Stripe Connect move — these are structural and painful to retrofit.
2. **Launch-shaping decisions:** customer-ID bar, auto-accept toggle + accept-window,
   welcome emails.
3. **Fast follows:** Apple Pay, discount codes.
4. **Growth bets:** web app, commercial jobs, blog.
