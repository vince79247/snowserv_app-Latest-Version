-- ROOT CAUSE of "server-side pushes never arrive": pg_net was NEVER INSTALLED.
-- dispatch_jobs() (offer + auto-accept pushes) and the payout cron all call
-- net.http_post(...), which has been throwing "schema net does not exist" on
-- every single run — silently, because those calls sit inside
-- EXCEPTION WHEN OTHERS THEN NULL blocks (and cron reported "succeeded").
-- Client-triggered pushes (accept/decline re-dispatch) worked all along, which
-- is what made this so confusing to test.
CREATE EXTENSION IF NOT EXISTS pg_net;
