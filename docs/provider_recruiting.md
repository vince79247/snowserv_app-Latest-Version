# Provider Recruiting — Copy & Channels

**Written 2026-08-03.** For the Sept–Oct push ahead of a ~Nov 15 launch in Yonkers, NY.

**The clock:** contractors commit to winter work in **September and October**. Whoever is
going to be busy in November already is by then. Posting in November means recruiting the
people nobody else wanted. Most of what's below can be posted remotely — leads land in the
admin Providers tab (Leads pipeline) and get worked when Vince is back in October.

**Target: 5 providers who are approved AND `payouts_enabled`.** Not 5 signups — 5 who have
finished Stripe Connect onboarding. Budget a week of chasing between "he's interested" and
"he can actually be paid."

---

## ⚠️ The honesty rule

**SnowServ has zero customers.** Do not imply otherwise. No "busy season," no "steady
work," no invented job volume, no income claims we can't substantiate.

This isn't only ethics. Contractors talk to each other in a small market. Oversell it, they
sign up, get nothing in December, and tell everyone SnowServ is a waste of time — and
you've burned the exact network you need. Under-promising to a contractor who then gets
paid on time is how you get the next three by referral.

The honest pitch is genuinely good: **we're new, you get first pick, and you keep 75%.**

---

## The pay math (use real numbers, they will)

Yonkers zone pricing, **verified against the live `service_areas` row 2026-08-04**. Provider
keeps **75%** (`app_settings.commission_pct` = 25).

| Job | Customer pays | **Provider gets** |
|---|---|---|
| Sidewalk only | $80 | **$60** |
| Driveway only | $120 | **$90** |
| Sidewalk + driveway | $160 | **$120** |
| Both + deicer | $250 | **$187.50** |

Storm pricing multiplies the whole job when snow is deep (up to 2× at 10"+). A
sidewalk+driveway at 1.5× is **$240 to the customer, $180 to the provider** — same work,
deeper snow.

⚠️ **Re-check these before every posting run.** Zone prices are admin-editable and live in
the database, not in code — this table was wrong by ~25% for a day because prices were
raised in the admin panel and the copy wasn't. Quoting a contractor a number and paying him
a different one is the fastest way to lose him and everyone he talks to.

Say "you keep 75%, we take 25%" plainly. Every contractor asks; answering before they do
buys more credibility than any adjective.

---

## Craigslist — Westchester → gigs → labor/moving

Post as a **gig**, not a job. They're 1099 contractors, not employees, and the wrong
category gets flagged.

**Title options** (rotate; CL flags duplicate posts):
- `Snow removal contractors wanted — Yonkers — keep 75%, paid weekly`
- `Plow/snowblower operators — Yonkers — new app, first crew forming`
- `Snow contractors: we send you the jobs, you keep 75%`

**Body:**

> **Snow removal contractors — Yonkers, NY**
>
> SnowServ is a new snow-removal app launching in Yonkers this winter. Customers request
> service from their phone, and we send the job to the nearest available contractor. We're
> putting together our first crew now, before the season starts.
>
> **How it pays**
> You keep **75%** of every job. We keep 25%. That's the whole arrangement — no signup fee,
> no monthly fee, no lead fee, no charge for the app.
>
> What you take home, per job:
>
> - Sidewalk only: **$60**
> - Driveway only: **$90**
> - Sidewalk + driveway: **$120**
> - Sidewalk + driveway + deicer: **$187.50**
>
> Deicer is an add-on — it pays you extra on top of any of these. Deep snow pays more too:
> pricing scales with depth, up to double in a big storm.

(Quoting the deicer add-on as a single figure was removed on purpose: once deicer is priced
per surface, "another $67.50" is only true for the both-surfaces job. The tier list carries
the concrete number a contractor actually needs, and stays correct through that change.)
>
> Paid by direct deposit, weekly. The customer's card is authorized before the job is sent
> to you, so you're not chasing anyone for money.
>
> **How it works**
> Job comes to your phone with the address, the work, the distance, and your pay. Accept or
> decline — no penalty either way. Take a photo when you're done and you're paid.
>
> **What you need**
> - Your own equipment (shovel, snowblower, or plow — plow/blower gets you the bigger jobs)
> - A smartphone
> - Insurance and a driver's licence for the file
> - To work as an independent contractor (1099)
>
> **Being straight with you:** we're brand new and haven't launched yet, so nobody can
> promise you a certain number of jobs. What we can promise is that the early contractors
> get first pick as customers come in, and that you'll be paid on time and in full.
>
> Interested? Read the details and leave your info here: https://app.snowserv.app
> Tap "Plow with us" — takes about a minute, no account needed.
>
> Or reply to this post if you'd rather ask a question first.

**The URL goes FIRST, deliberately.** "Plow with us" is NOT the five-step registration — it
opens the no-account interest form (`provider_interest_screen.dart` → `provider_leads`):
name, phone or email, ZIP, equipment, notes. A minute, no documents. That makes the website
the *better* channel, not merely the more convenient one: you capture equipment type and
ZIP as structured fields that map onto what dispatch cares about, and every lead lands in
the admin Leads pipeline where they can be worked in one batch — instead of arriving as
free-text emails someone has to read and retype.

Reply-to-post stays as a second option because CL's mail relay is free and some contractors
would rather ask a human before typing anything.

**Two caveats:**
- **Leads arrive silently.** Nothing pushes or emails when the form is submitted — check the
  admin Leads tab. A contractor who fills it in and hears nothing for weeks goes cold, so
  batch a reply pass at least weekly during the recruiting window.
- **The form hardcodes `source: 'website form'`**, so Craigslist, Facebook and word-of-mouth
  leads are indistinguishable. If channel attribution matters for deciding where to spend
  October, that needs a per-channel source before the posts go up.

**On formatting:** CL supports `<a href>` only in certain paid categories, so in gigs expect
a bare, possibly non-clickable URL. `app.snowserv.app` is short enough to type from a phone,
which is the whole reason the custom domain was worth setting up.

---

## Facebook groups

Post as a person, not a brand. Groups delete corporate ad copy and keep neighborly posts.

**Where:** Yonkers/Westchester community groups, Westchester landscaper & contractor
groups, regional snow-plowing groups ("Snow Plowing Northeast" and similar), local
buy/sell/trade groups. **Read each group's self-promo rules first** — some require a
specific day or admin approval, and getting banned costs you the whole group.

**Post:**

> Hey all — I'm starting a snow removal app in Yonkers this winter and I'm looking for
> contractors to work it.
>
> Simple setup: customer orders from their phone, the job goes to the closest available
> contractor, you keep 75%. Driveway pays you $90, driveway + sidewalk $120, more when
> the snow's deep. Direct deposit weekly, card authorized before the job's sent out so
> you're never chasing payment.
>
> You need your own equipment and insurance. Plow or blower is ideal — that's where the
> bigger jobs go.
>
> Straight up: we launch in November and I'm building the crew now, so I can't tell you how
> many jobs there'll be. Early guys get first pick. If that's worth a shot, comment or DM
> and I'll send the link.

---

## Reply template (for comments and DMs)

Keep it short. The goal is one link, not a pitch.

> Thanks for reaching out. Quick version: you keep 75% of each job, paid weekly by direct
> deposit. Driveway is $90 to you, driveway + sidewalk $120, more in deep snow. You need
> your own equipment, insurance, and a smartphone. No fees to join.
>
> Sign-up is here: https://app.snowserv.app (tap "Plow with us"). Takes a few minutes.
> Any questions, just ask — happy to talk it through.

---

## Objections they will raise, and honest answers

**"What's the catch? What do you take?"**
25%. No signup fee, no monthly fee, no lead fee. If you don't work, you don't pay anything.

**"When do I actually get paid?"**
Weekly, by direct deposit to your bank. The customer's card is authorized before the job
reaches you and charged when you start, so the money exists before you do the work.

**"How many jobs will I get?"**
Nobody can tell you yet — we're new and launching in November. That's the honest answer.
What we control is that early contractors get the jobs first as they come in.

**"Am I an employee?"**
No. Independent contractor, 1099. Your equipment, your hours, your call on every job.
Stripe handles the tax form.

**"Do I have to take every job?"**
No. Decline anything, any time, no penalty. The job goes to the next contractor.

**"Do I need insurance?"**
Yes — you upload it during signup, along with your licence. That protects you as much as us.

**"What if the customer says I damaged something?"**
You take photos before and after, right in the app. Those settle almost every dispute.

**"Why wouldn't I just get my own customers?"**
Plenty of contractors do both. This is for filling the gaps — you're not paying to
advertise, you're not answering the phone, and you're not chasing anyone for a check.

**"What stops you taking my customers?"**
Fair question. There's a non-solicitation clause in the contractor agreement about not
taking SnowServ customers off-platform — same as any referral arrangement. Customers you
already had are yours; nothing about them changes.

---

## Also worth doing (October, in person)

- **Landscaping/equipment suppliers** — flyer on the counter or bulletin board. This is the
  single highest-signal channel: everyone in that shop already owns a plow.
- **Small-engine repair shops** — same crowd, and October is when they're getting blowers
  serviced.
- **Ask the first two who sign up who else they'd work with.** Referral is how contractor
  crews actually form, and it costs nothing.

---

## Do NOT

- **No cold email to scraped contractor lists.** Illegal-adjacent under CAN-SPAM, and it
  torches the sending reputation that took a day to fix (see [[email_setup.md]]).
- **No income claims** — "make $500 a storm" is unsubstantiated and it's the fastest way
  to end up with resentful contractors.
- **No implying we have customers.** We have zero.
- **Don't post identical text everywhere** — Craigslist flags duplicates and Facebook
  throttles copy-paste.

## Track it

Every lead lands in **admin → Providers tab → Leads**. Set a source when adding manually so
you learn which channel actually works — with a handful of leads that's the difference
between guessing and knowing where to spend October.
