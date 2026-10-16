# A business phone number — Twilio vs Google Voice vs OpenPhone

Written **2026-10-16** while Vince was away. Trigger: Isaiah texted his personal
cell, and every provider recruited from here will do the same. Requirement he
stated: a number **Claude can respond on**.

---

## The one-line version

**Google Voice cannot do what you asked.** It has no API — there is no supported
way for me to read or send texts through it, and automated use is against its
terms. If you want me on your texts, it is Twilio or something like it.

But first, the expectation that matters:

## ⚠️ "Claude responds to my texts" is something we BUILD, not something you buy

Twilio is a pipe, not an assistant. What you actually get on day one is a phone
number with an API. The responding part is work, and it comes in stages:

| Stage | What it means | Effort |
|---|---|---|
| **1. Receive** | Inbound texts hit an edge function, get stored, and show in the admin panel beside `email_log` | a few hours |
| **2. Reply with me** | I read the thread and draft; the reply sends from the panel. Like today's emails, but texts | small |
| **3. Autonomous** | It answers providers on its own, no review | ⚠️ bigger, and riskier |

Stage 3 is where the money is and where the danger is. An auto-reply that tells
a provider the wrong thing about payouts is worse than silence, and you have
already paid once for a message that said the wrong thing (Isaiah, ten weeks).
**Recommend stopping at stage 2 through this first season.**

The good news: stages 1–2 slot straight into what exists. Supabase edge
functions, a Postgres table, an admin panel that already renders `email_log`.
An SMS log is the same pattern again — this is a short build, not a project.

---

## TWILIO

**Pros**
* **Real API.** Send and read programmatically. This is the only reason to be here.
* **Webhooks** — an inbound text POSTs to an edge function in real time, exactly
  like `stripe-webhook` already does. Familiar shape, familiar stack.
* **One contact history.** SMS could log to the same place as `email_log`, so a
  person's card finally shows everything we ever said to them in one list.
  That is the thing `email_log` was built for and email is only half of it.
* Programmable voice too — forward calls to his cell, or answer with
  "text this number, I do everything in writing," which matches how he works.
* Later: SMS job alerts to providers whose push notifications are off. Push has
  already failed silently once (APNs sandbox key, two weeks).
* Carrier-legitimate once registered, so messages are not quietly filtered.

**Cons**
* **No app.** Twilio gives you an API and a clunky console, not a texting app.
  Until stage 1 is built you cannot practically text from your phone at all.
  ⚠️ This is the real cost and it is not money.
* **A2P 10DLC registration is mandatory** for business texting to US numbers.
  Brand + campaign, vetted by carriers, **about a week**, and unregistered
  traffic gets filtered or blocked. Cannot be skipped.
* ⚠️ **You do NOT qualify as a "Sole Proprietor" brand.** That tier is for
  senders *without* a business Tax ID. SnowServ LLC has an EIN, so you register
  as a Standard brand — different, somewhat higher fees. Confirm in the console.
* Compliance is on you: STOP/opt-out handling, consent records.
* Another account to secure. ⚠️ Set up TOTP + backup codes at creation, not
  later — the Stripe lesson cost 12 hours.

## GOOGLE VOICE

**Pros**
* Free, and running in ten minutes.
* Real US number, calls + texts, rings his phone, works on the web.
* Voicemail transcription is genuinely good.
* Solves the actual immediate problem — *stop handing out your personal cell*.

**Cons**
* ❌ **No API.** Not a limitation to engineer around; there is no supported
  interface. Automated use also violates the terms.
* Can be reclaimed if it sits unused.
* Not built for business messaging compliance.
* **So it fails the one requirement that prompted this.**

## OPENPHONE — the option not yet considered

A business phone product with **both** a real iPhone/Android app **and** an API
with webhooks. Twilio under the hood, a usable app on top.

**Pros**
* You can text from your phone **on day one**, with no build at all.
* API + webhooks, so stages 1–2 remain possible later.
* Handles 10DLC registration for you.
* Shared inbox, so a second person can be added without changing numbers.

**Cons**
* ~$15–19 per user per month — more than Twilio's raw cost. **Confirm current pricing.**
* Less control than owning the Twilio account directly.
* One more vendor between you and the carrier.

---

## Cost — Twilio, at your volume

| | |
|---|---|
| Local number | ~$1.15/month |
| Brand registration | ~$4.50 one-time |
| Campaign vetting | ~$15 one-time |
| Monthly campaign fee | ~$2–10/month (Standard brand, confirm) |
| Per text, all-in | ~$0.012–0.013 including carrier fees |
| 500 texts/month | ~$6 |
| **Realistic total** | **~$10–20/month** |

⚠️ Figures are from third-party summaries that disagree with each other —
Twilio's own pricing page is the authority. But the shape is certain: **cost is
not the deciding factor here.** At these numbers it is noise next to the $453/yr
software stack, let alone insurance. Decide on capability and effort, not price.

---

## Recommendation

1. **Get the number NOW, before recruiting more providers.** Every person who
   gets the personal cell is permanent — you cannot un-give a number. This is
   the part with a deadline, not the integration.
2. **Do not run two numbers.** Picking Google Voice today and Twilio later means
   changing your number on everyone you have recruited. Choose once.
3. **If you want to text from your phone this week → OpenPhone.** App on day one,
   API when we are ready, 10DLC handled for you. Costs more, saves the gap.
4. **If you want to own the whole thing → Twilio**, and accept that until stage 1
   is built you are texting from a web console.
5. **Start 10DLC registration the same day either way.** It takes about a week
   and nothing works properly until it clears. Snow is ~3 weeks out.

⚠️ **Either way, do NOT text providers from the personal cell again** once a
business number exists. Mixing personal and company identity is the same thing
we flagged on email, and for a single-member LLC it is a liability-shield issue,
not a style one.
