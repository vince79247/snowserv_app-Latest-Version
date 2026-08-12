# Conversational AI agent — build spec

**Status:** approved to spec, NOT started. Written 2026-08-12. Target: second
season, after launch — see §8 for why.

**Vince's ask (2026-08-12):** *"Is there a way to create an AI agent that works
with this app so people don't have to push any buttons? They could just talk to
the app, and the AI agent will do everything."*

Short answer: yes, with one exception that is not negotiable — **they will still
push one button, and it is the Pay button.** §4 explains why that is a feature.

---

## 1. What already exists

`supabase/functions/support-draft` is live: an admin pastes an inbound message,
Claude writes a reply draft grounded in a hardcoded knowledge base, and a human
reviews and sends it. `ANTHROPIC_API_KEY` is already a Supabase secret. The
auth model there is already right — `verify_jwt` on, plus an explicit
`profiles.is_admin` check so a customer cannot burn the API budget.

So the foundation is built. This spec is about widening it from "draft an email
for a human" to "talk to the customer directly".

### ⚠️ Fix this before building anything on top of it

**The existing knowledge base has drifted from reality and is wrong today.**
Verified against the live `service_areas` row on 2026-08-12:

| Fact | Knowledge base says | Actually |
|---|---|---|
| Sidewalk | $50 | **$80** |
| Driveway | $100 | **$120** |
| Sidewalk + Driveway | $125 | **$160** |
| Deicer | +$40 flat | **$45 / $70 / $90 per surface** |
| Storm bands | 1.3× / 1.7× / 2.3× | **1.2× / 1.5× / 2.0×** |
| Dispatch | "nearest + least busy" | equipment → load → distance band → **rating**, and suspended providers excluded |

Every number is wrong, and the drafts it writes get emailed to real people over
the signature "The SnowServ Team". This is exactly the decay CLAUDE.md warns
about, and it is the single most important design constraint below: **an agent
must read facts from the database at call time, never from a string a developer
typed once.** See §6.

---

## 2. Three agents, not one

They differ in who they talk to and what they can touch. Build them in this
order.

### A. Support agent (customer- and provider-facing) — build FIRST
Answers "where is my provider", "why was I charged $192", "can I add deicer",
"how do payouts work". Every answer is a database lookup or a policy statement.

This is where the value is. These questions arrive at 6am during a storm, they
are repetitive, and they otherwise land on Vince personally. It is also the
lowest-risk surface because it is **read-only**.

### B. Ordering agent (customer-facing) — build SECOND
"Do my driveway and the sidewalk at Mom's before 6am." The order is small and
bounded — address, surfaces, deicer, timing — and every one of those fields
already exists. The agent fills the order and hands back a confirmation card.

### C. Admin agent — build LAST, or never
"Which providers can't work?", "refund job 1184". Tempting and genuinely useful,
but it is the surface where a mistake costs money, and the admin panel already
does these things in one tap. Low value, high blast radius.

---

## 3. Architecture

```
app (chat sheet)
  → edge fn  agent-chat        verify_jwt ON
      ├── loads live facts (§6)
      ├── Anthropic Messages API with TOOLS
      ├── executes read tools AS THE CALLER (§5)
      └── returns { reply, proposed_action? }
  → app renders reply, and if proposed_action is an order,
    renders a real OrderConfirmationCard with a Pay button
```

**One new edge function.** `agent-chat`, modeled on `support-draft`'s auth.
Conversation history is passed from the client each turn (no server session
store in v1) and capped — say 20 turns — so context cannot grow unbounded.

**Model choice.** `claude-haiku-4-5` is enough for support answers and is what
`support-draft` already uses. Use a Sonnet-class model for the ordering agent:
it follows the "never state a price you did not read from a tool" rule more
reliably, and ordering is the money path.

**Voice is a thin layer on top, added last.** Speech-to-text on the device feeds
the same text pipeline; replies can be spoken back. Do not build voice first —
if the text agent is wrong, a talking version is wrong out loud.

---

## 4. The rule that does not bend: no unattended money

**The agent NEVER charges, refunds, captures, or cancels.**

It may *propose* an order. The app then renders a real confirmation card — the
address, the surfaces, the deicer, the storm multiplier and the total — and the
customer taps Pay, which goes through the existing `create-checkout-session`
path unchanged. Same server-authoritative pricing, same hold model, same
webhook.

Three reasons, in order of importance:

1. **The price must be the server's, not the model's.** `create-checkout-session`
   already recomputes everything and ignores any client-sent amount. Routing the
   agent through it means a hallucinated price is impossible by construction —
   the worst case is the confirmation card shows a number the customer declines.
2. **Consent.** A hold on someone's card needs a deliberate act. "I thought I was
   just asking a question" is a chargeback and a bad review.
3. **Stripe requires it anyway.** Checkout is a hosted page; there is no
   API-only path that keeps the wallet options and the hold semantics.

So "no buttons" becomes "one button, at the only moment that matters". Worth
saying plainly to Vince rather than quietly shipping something narrower than he
asked for.

The same rule applies to cancellation: the agent explains the consequence
("you're before start, so the hold is released and you're not charged") and
surfaces the existing Cancel button. It does not call `refund-job`.

---

## 5. Data access — the agent inherits the user's permissions

**Non-negotiable: read tools execute with the CALLER's JWT, not the service
role key.** RLS is what makes it structurally impossible for the agent to read
another customer's orders — not prompt instructions, which are a request, not a
boundary.

`support-draft` uses the service key today, which is fine because it never sees
user data. `agent-chat` will, so it must not.

Tool surface for the support + ordering agents:

| Tool | Returns | Notes |
|---|---|---|
| `get_my_active_jobs` | the caller's open jobs + status | RLS-scoped |
| `get_my_order_history` | completed jobs + receipts | RLS-scoped |
| `get_my_addresses` | saved properties + labels | RLS-scoped |
| `get_quote` | live zone prices + current storm multiplier | the ONLY source of a price |
| `get_policy` | hold-vs-charge, cancellation, ratings, payouts | from the FAQ content |
| `propose_order` | a draft order for the confirmation card | writes nothing |

**Hard exclusions, enforced server-side by never exposing the field:**

- **`provider_notes` must NEVER reach a customer.** Admin-only, always.
- **Never tell a customer the provider's 75% cut.** It invites paying the
  provider directly, which the Service Agreement forbids.
- Never expose another user's name, address, phone, or card details.
- Never quote a price that did not come from `get_quote`.

---

## 6. Grounding: facts from the database, never from a string

This is the lesson of §1. The agent's system prompt is **assembled at call
time** from live data:

- prices → the matched `service_areas` row for the caller's address
- storm bands → `app_settings.storm_bands`
- commission → `app_settings.commission_pct`
- dispatch window → `app_settings.dispatch_timeout_seconds`
- policy prose → one shared source with the FAQ

The FAQ screen already does exactly this for storm tiers, commission, and the
offer window, precisely because hardcoded copies went stale and contradicted
what customers were charged. The agent must be built the same way from day one,
because a wrong number spoken confidently by an assistant is worse than a wrong
number in a help article — people act on it.

**Test for this directly** (§9): change a zone price in the admin panel, ask the
agent what a driveway costs, and assert the new number comes back.

---

## 7. Cost

Pennies per conversation, not dollars, and it scales with usage rather than
being a fixed monthly cost. A support exchange is a few thousand tokens; an
ordering conversation is a few more. At launch volumes this is rounding error
against one $160 job.

Two guards worth having from the start, since the endpoint is authenticated but
still user-triggered:

- a per-user daily message cap (a row in `app_settings`, admin-editable)
- `max_tokens` capped per reply, as `support-draft` already does

Neither is about the bill; they are about a runaway loop.

---

## 8. Why this is a second-season feature

Nothing here decides whether SnowServ works this winter. What decides that is
whether enough providers are online when it snows in Yonkers — a recruiting
problem, not an input-method problem. Two of five approved providers could not
take a job at all as of this morning.

Build it when there is real conversation volume to learn from. Guessing at what
customers will ask, before a single real customer has asked anything, produces a
knowledge base that is wrong in ways nobody predicted — which is how the current
one ended up wrong.

**It does fit the platform strategy.** A support agent that understands
"dispatch, hold, capture, payout" is not snow-specific; it works identically for
lawn care. Build it once on the shared platform, not once per vertical.

---

## 9. Test checklist

- [ ] Change a zone price in the admin panel → the agent quotes the NEW price
- [ ] Ask about a storm multiplier → matches `app_settings.storm_bands`
- [ ] Customer A asks about Customer B's order → refuses, and RLS returns nothing
      even if the model tries
- [ ] Ask "what did my provider write about my property" → never returns
      `provider_notes`
- [ ] Ask "how much does my provider make" → declines
- [ ] "Cancel my job" → explains hold-vs-charge, surfaces the button, calls
      nothing
- [ ] "Order a driveway" → confirmation card whose total equals
      `create-checkout-session` for the same selection, to the dollar
- [ ] Ask a question with no answer in the knowledge base → says a human will
      follow up rather than inventing one
- [ ] Unauthenticated call → 401
- [ ] Daily cap → refuses politely

---

## 10. Deliberately not doing

- **Agent-initiated charges, refunds, captures or cancellations.** §4.
- **Voice first.** Text first; voice is a wrapper once the text agent is right.
- **Replacing the buttons.** The agent sits alongside the UI. Plenty of people
  will always tap, and a storm morning is the worst time to force anyone to
  learn a new way to order.
- **A hardcoded knowledge base.** §6. This is how the current one broke.
- **An admin agent that can act.** §2C — the admin panel already does it in one
  tap, and that is the surface where a mistake costs money.
