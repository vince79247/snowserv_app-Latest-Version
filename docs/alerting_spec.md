# Operational alerting — build spec

**Status:** approved to spec 2026-08-13, NOT started. Recommended BEFORE launch,
ahead of any conversational agent.

**Why it outranks the AI agent:** an agent answers customers. This tells Vince
his business is broken. At 4am on the first real storm, the second one matters
more — and unlike the agent, it needs no model and no training data.

---

## 1. The problem, stated from evidence

Every serious defect found in the 2026-08-11→13 sessions had the same shape:
**it reported success while failing.**

| What broke | What it reported |
|---|---|
| Storm-booking cron, 401 every 30 min since it was built | `cron.job_run_details`: **succeeded** |
| Saved cards never usable at checkout | app cheerfully showed "Card on file" |
| Price math forked into three copies | each copy internally consistent |
| Storm-readiness dashboard | "3 providers can work" — all three test accounts |
| Suspension | button worked, dispatch ignored it |

None were caught by a test, a type checker, or a log. Every one was caught by a
human going and looking.

**At 4am during a storm nobody is going and looking.** That is the whole reason
this exists.

## 2. The rule for what earns an alert

> Alert only on conditions that need a HUMAN DECISION, and say what to do.

Not "something happened" — something is wrong, money or a customer is exposed,
and a person must act. Anything that does not meet that bar is a dashboard
number, not an alert.

Alert fatigue is the failure mode. A phone that buzzes for routine events gets
silenced, and then the one that mattered is silenced too. **Fewer, louder.**

---

## 3. What to alert on

### WAKE ME — push to Vince's phone, immediately

FCM to admin devices already works (proven on iOS 2026-08-12). These are the
only conditions worth waking someone for.

| Condition | Why it cannot wait | Detect |
|---|---|---|
| **Capture failed** | The provider is clearing a driveway RIGHT NOW for free. The card was never charged. | `jobs.capture_failed = true` |
| **Job stranded past give-up** | Customer paid, nobody came, hold about to be auto-released. | `status='requested'` older than `stranded_giveup_minutes` |
| **Jobs exist and zero providers online** | Every order placed in the next hour will strand. | open jobs > 0 AND online approved+payable = 0 |
| **A cron stopped succeeding** | Exactly yesterday's bug. | last `net._http_response` for that job is non-2xx, or no run in 2× its interval |
| **Stripe webhook silent** | Payments taken, no jobs created. The worst possible failure. | a Checkout session completed with no matching job after 5 min |

### TELL ME LATER — one daily digest email, 7am

| Condition | Why it can wait |
|---|---|
| Provider cancelled after start | Already handled; the counter matters over time |
| Job `in_progress` > 4h | Provider probably forgot to tap Complete |
| Approved provider still payout-blocked | The banner now nags them; this is your backstop |
| Registration stalled > 7 days | Recruiting follow-up, not an emergency |
| Payout batch results | Money out, worth reading, never urgent |

### Never alert
Order placed · job completed · rating left · provider went online. That is a
dashboard, and pushing it trains you to ignore the phone.

---

## 4. The watchman problem — read this before building

**The alerting cannot be the thing that reports its own death.** Yesterday's
cron could not tell anyone it was failing, because it was failing.

So two layers, and the second is not optional:

1. **Internal rules job** — pg_cron every 5 min, evaluates §3, sends alerts.
2. **External heartbeat** — the rules job stamps `app_settings.last_health_ok`
   on every clean run. A **third-party uptime monitor** (UptimeRobot / Better
   Stack, free tier) hits a tiny public `health` endpoint that returns **503 if
   that stamp is older than 15 minutes**. The monitor emails/SMSs Vince.

Layer 2 is what catches total failure — Supabase down, the cron unscheduled, the
project paused on the free tier. **Something outside the system has to watch
it**, or you are back to a cron reporting its own success.

`health` must be unauthenticated (monitors cannot log in) and must leak nothing
— just a status code and `{"ok":true|false}`.

---

## 5. Delivery

- **Push (wake-me)** — reuse the FCM path. Needs a small `notify-admin`
  function: look up `profiles.is_admin` with a token, send. All the machinery
  exists; nothing new to learn.
- **Email (digest + fallback)** — Resend is wired, and `email_log` already
  records every send, so alert history is free.
- **SMS** — the strongest 4am channel and deliberately deferred. It depends on
  the business-number decision parked until October. Push is good enough to
  start; revisit with Twilio if push proves unreliable in practice.

**De-duplicate.** One alert per incident, not one per tick. The
`stranded_notified_at` latch is the pattern to copy — a nullable timestamp per
condition, cleared when it resolves.

---

## 6. Implementation sketch

```
app_settings
  alerts_enabled            'true'
  alert_quiet_hours         '' (empty = never quiet; storms do not respect them)
  last_health_ok            timestamptz stamped by every clean run

new table  alerts
  id, kind, severity, subject_id, message, created_at, resolved_at,
  notified_at            -- the de-dup latch

edge fn    notify-admin       push to every is_admin device
edge fn    health             public; 503 when last_health_ok is stale
pg_cron    check-health       every 5 min -> evaluates rules -> writes alerts
                              -> calls notify-admin -> stamps last_health_ok
```

Cron auth uses the **Vault secret**, not `current_setting('app.service_role_key')`
— see [[reference-pg-cron-silent-401]]. That parameter cannot be set on Supabase
and is what caused the original silent failure.

---

## 7. Rollout

1. `alerts` table + `last_health_ok`. Inert.
2. `notify-admin`, tested against Vince's own device.
3. `check-health` with **only the two money rules** (capture failed, webhook
   silent). Run a week. Confirm zero false alarms.
4. Add the remaining wake-me rules.
5. Daily digest.
6. External monitor last, once the health endpoint has been stable for a week.

Staged deliberately: an alerting system that cries wolf in week one gets muted
in week two, and then it is worse than nothing.

---

## 8. Test checklist

- [ ] Force `capture_failed=true` on a test job → push arrives within 5 min
- [ ] Same condition still true 30 min later → **no second push** (de-dup)
- [ ] Condition resolves → `resolved_at` set, no further alerts
- [ ] Stop the rules cron → health endpoint returns 503 within 15 min
- [ ] Health endpoint leaks no data and needs no auth
- [ ] Zero alerts fire during a normal order → complete → payout cycle
- [ ] Alerts respect `alerts_enabled=false`

---

## 9. Deliberately not doing

- **Alerting on normal business events.** §3 "never" list. The value of this
  system is entirely in how rarely it fires.
- **An AI summarising alerts.** An alert should be readable in three seconds by
  someone half asleep. A model between the fact and the phone adds latency and a
  chance of being wrong about an emergency.
- **Self-healing.** Nothing here retries payments or reassigns jobs on its own.
  It tells a human. Automatic recovery on the money path is how a bad night
  becomes an expensive one.
- **SMS at launch.** Parked with the business-number decision (October).
