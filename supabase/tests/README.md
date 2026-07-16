# Dispatch tests

Automated proof that job routing works — without any app, simulator, or login.

## Run it
```bash
./supabase/tests/run_dispatch_test.sh
```
Every check must print `PASS`. The script exits non-zero if anything fails, so it
can drop straight into CI or a pre-release checklist. It's **read-only** — it
writes nothing to the database and sends no push notifications, so it's safe to
run against production anytime.

No token? `supabase login` first (the script reads that token from the macOS
keychain), or set `SUPABASE_ACCESS_TOKEN`.

Prefer clicking? Open the Supabase dashboard → **SQL Editor**, paste
[`dispatch_ranking_test.sql`](dispatch_ranking_test.sql), and Run. Every row
should say `PASS`.

## What it proves
It runs the **exact** ranking logic from the live `dispatch_jobs()` function
against 50 synthetic providers plus targeted scenarios, and asserts:

- **Eligibility** — offline, unapproved, already-declined, and self-as-customer
  providers are never offered a job.
- **Load-aware + nearest** — fewest active jobs first, then proximity; the
  physically-closest driver is *not* picked if they're already busy.
- **Decline cascade** — the pick order is a correct sort, so each decline hands
  off to the right next driver, all the way down.
- **Preferred driver** — a live-preferred driver wins an equal-or-closer call
  but is never handed a worse-distance job.
- **Auto-accept** — an auto-accept winner is assigned directly (no offer countdown).
- **Offer timeout** — a stale offer expires, the provider is rejected, and the
  re-dispatch promotes the next driver.

## Why you can trust it (drift guard)
The test mirrors the production SQL, so it could theoretically fall out of sync.
To prevent that, several `guard_*` checks read the **live** `dispatch_jobs()`
source and assert it still contains the formulas the test mirrors. If someone
changes the real ranking, those guards fail — telling you the mirror is stale
instead of silently passing. (Verified by a negative-control run: deliberately
breaking the logic makes the matching checks FAIL.)
