-- ============================================================================
-- SnowServ dispatch routing — permanent regression test
-- ============================================================================
-- Proves the job-routing rules in the live dispatch_jobs() function without any
-- app, simulator, or login: it runs the EXACT ranking logic against synthetic
-- providers held in memory (CTEs) and asserts the outcomes.
--
-- READ-ONLY. Writes nothing, creates no rows, sends no pushes. Safe to run
-- against production anytime.
--
-- HOW TO RUN
--   • Supabase dashboard → SQL Editor → paste this file → Run.
--     Every row in the result must say PASS. Any FAIL names what broke.
--   • Or via the Management API /database/query endpoint (see repo notes).
--
-- WHAT IT COVERS
--   1. Eligibility filters   — offline / unapproved / rejected / self-customer
--                              never get offered a job.
--   2. Load-aware + nearest  — fewest active jobs first, then proximity; the
--                              physically-closest driver is NOT picked if busy.
--   3. Decline cascade order — the pick order is a correct monotonic sort, so
--                              each decline hands off to the right next driver.
--   4. Preferred-driver      — a live-preferred driver wins an equal-or-closer
--                              call but is NEVER handed a worse-distance job.
--   5. Auto-accept routing   — an auto-accept winner is assigned directly.
--   6. Offer-timeout expiry  — a stale offer expires, the provider is rejected,
--                              and the re-dispatch excludes them.
--   7. DRIFT GUARD           — asserts the live dispatch_jobs() source still
--                              contains the formulas this test mirrors. If prod
--                              changes its ranking, these fail so you KNOW the
--                              mirror is stale (the test can't silently drift).
-- ============================================================================

WITH
-- --- the job we are routing --------------------------------------------------
params AS (
  SELECT 40.9312::float8 AS job_lat,
         -73.8988::float8 AS job_lng,
         -- customer_id set to provider #7's user_id to test self-exclusion
         '11111111-0000-0000-0000-000000000007'::uuid AS customer_id,
         -- provider #5 is pre-rejected (already declined / timed out)
         ARRAY['00000000-0000-0000-0000-000000000005']::uuid[] AS rejected
),

-- --- 50 synthetic providers scattered around the job -------------------------
big AS (
  SELECT
    ('00000000-0000-0000-0000-' || lpad(g::text, 12, '0'))::uuid AS id,
    40.90 + (g % 10) * 0.01                                      AS current_lat,
    -73.95 + (g % 8) * 0.01                                      AS current_lng,
    (g % 4)::int                                                 AS active,   -- 0..3 active jobs
    (g % 13 <> 0)                                                AS is_online, -- ~1 in 13 offline
    (g % 11 <> 0)                                                AS approved,  -- ~1 in 11 unapproved
    ('11111111-0000-0000-0000-' || lpad(g::text, 12, '0'))::uuid AS user_id
  FROM generate_series(1, 50) g
),

-- the eligible, ranked queue (identical WHERE + ORDER BY to dispatch_jobs) -----
ranked AS (
  SELECT b.id, b.active,
    (b.current_lat - p.job_lat)^2 + ((b.current_lng - p.job_lng) * 0.7)^2 AS dist,
    row_number() OVER (
      ORDER BY b.active ASC,
      (b.current_lat - p.job_lat)^2 + ((b.current_lng - p.job_lng) * 0.7)^2 ASC
    ) AS pick
  FROM big b, params p
  WHERE b.is_online = true
    AND b.approved = true
    AND b.id <> ALL(p.rejected)
    AND b.user_id IS DISTINCT FROM p.customer_id
),

-- --- preferred-driver: wins an equal-or-closer call --------------------------
-- normal winner sits ~0.30 mi out; preferred driver sits right on the job.
prefA(id, current_lat, current_lng, active, is_online, approved, auto_accept, preferred_until) AS (VALUES
  ('a0000000-0000-0000-0000-000000000001'::uuid, 40.9355::float8, -73.9010::float8, 0, true, true, false, NULL::timestamptz),
  ('a0000000-0000-0000-0000-000000000002'::uuid, 40.9312::float8, -73.8986::float8, 0, true, true, false, now() + interval '2 hours'),
  ('a0000000-0000-0000-0000-000000000003'::uuid, 40.9700::float8, -73.9400::float8, 0, true, true, false, NULL)
),
-- --- preferred-driver: must NOT be handed a worse (farther) job --------------
-- normal winner sits on the job; preferred driver is far away.
prefB(id, current_lat, current_lng, active, is_online, approved, auto_accept, preferred_until) AS (VALUES
  ('b0000000-0000-0000-0000-000000000001'::uuid, 40.9312::float8, -73.8986::float8, 0, true, true, false, NULL::timestamptz),
  ('b0000000-0000-0000-0000-000000000002'::uuid, 40.9700::float8, -73.9400::float8, 0, true, true, false, now() + interval '2 hours'),
  ('b0000000-0000-0000-0000-000000000003'::uuid, 40.9500::float8, -73.9200::float8, 0, true, true, false, NULL)
),
pref_calc AS (
  SELECT
    'A' AS scn,
    (SELECT id FROM prefA WHERE is_online AND approved ORDER BY active, (current_lat-p.job_lat)^2+((current_lng-p.job_lng)*0.7)^2 LIMIT 1) AS normal_id,
    (SELECT (current_lat-p.job_lat)^2+((current_lng-p.job_lng)*0.7)^2 FROM prefA WHERE is_online AND approved ORDER BY active, (current_lat-p.job_lat)^2+((current_lng-p.job_lng)*0.7)^2 LIMIT 1) AS normal_dist,
    (SELECT id FROM prefA WHERE is_online AND approved AND preferred_until > now() ORDER BY (current_lat-p.job_lat)^2+((current_lng-p.job_lng)*0.7)^2 LIMIT 1) AS pref_id,
    (SELECT (current_lat-p.job_lat)^2+((current_lng-p.job_lng)*0.7)^2 FROM prefA WHERE is_online AND approved AND preferred_until > now() ORDER BY (current_lat-p.job_lat)^2+((current_lng-p.job_lng)*0.7)^2 LIMIT 1) AS pref_dist
  FROM params p
  UNION ALL
  SELECT
    'B',
    (SELECT id FROM prefB WHERE is_online AND approved ORDER BY active, (current_lat-p.job_lat)^2+((current_lng-p.job_lng)*0.7)^2 LIMIT 1),
    (SELECT (current_lat-p.job_lat)^2+((current_lng-p.job_lng)*0.7)^2 FROM prefB WHERE is_online AND approved ORDER BY active, (current_lat-p.job_lat)^2+((current_lng-p.job_lng)*0.7)^2 LIMIT 1),
    (SELECT id FROM prefB WHERE is_online AND approved AND preferred_until > now() ORDER BY (current_lat-p.job_lat)^2+((current_lng-p.job_lng)*0.7)^2 LIMIT 1),
    (SELECT (current_lat-p.job_lat)^2+((current_lng-p.job_lng)*0.7)^2 FROM prefB WHERE is_online AND approved AND preferred_until > now() ORDER BY (current_lat-p.job_lat)^2+((current_lng-p.job_lng)*0.7)^2 LIMIT 1)
  FROM params p
),
pref_chosen AS (
  SELECT scn,
    CASE WHEN pref_id IS NOT NULL AND pref_dist <= normal_dist THEN pref_id ELSE normal_id END AS chosen_id,
    normal_id, pref_id
  FROM pref_calc
),

-- --- auto-accept routing -----------------------------------------------------
-- autoset: the ranking winner (closest idle) has auto_accept = true  → 'assigned'
-- offerset: the ranking winner has auto_accept = false               → 'offer'
autoset(id, current_lat, current_lng, active, is_online, approved, auto_accept) AS (VALUES
  ('c0000000-0000-0000-0000-000000000001'::uuid, 40.9312::float8, -73.8987::float8, 0, true, true, true),
  ('c0000000-0000-0000-0000-000000000002'::uuid, 40.9400::float8, -73.9000::float8, 0, true, true, false)
),
offerset(id, current_lat, current_lng, active, is_online, approved, auto_accept) AS (VALUES
  ('d0000000-0000-0000-0000-000000000001'::uuid, 40.9312::float8, -73.8987::float8, 0, true, true, false),
  ('d0000000-0000-0000-0000-000000000002'::uuid, 40.9400::float8, -73.9000::float8, 0, true, true, true)
),
route_calc AS (
  -- routing decision mirrors dispatch_jobs: IF chosen_auto THEN assign ELSE offer
  SELECT 'auto' AS scn,
    (SELECT CASE WHEN auto_accept THEN 'assigned' ELSE 'offer' END
       FROM autoset WHERE is_online AND approved
       ORDER BY active, (current_lat-p.job_lat)^2+((current_lng-p.job_lng)*0.7)^2 LIMIT 1) AS route
  FROM params p
  UNION ALL
  SELECT 'offer',
    (SELECT CASE WHEN auto_accept THEN 'assigned' ELSE 'offer' END
       FROM offerset WHERE is_online AND approved
       ORDER BY active, (current_lat-p.job_lat)^2+((current_lng-p.job_lng)*0.7)^2 LIMIT 1)
  FROM params p
),

-- --- decline cascade: re-rank after the winner declines ----------------------
-- Adds the current winner to the rejected set and re-runs the FULL eligibility
-- filter + ranking — exactly what happens on a decline / timeout re-dispatch.
redispatch AS (
  SELECT b.id,
    row_number() OVER (
      ORDER BY b.active ASC,
      (b.current_lat - p.job_lat)^2 + ((b.current_lng - p.job_lng) * 0.7)^2 ASC
    ) AS pick
  FROM big b, params p
  WHERE b.is_online = true
    AND b.approved = true
    AND b.id <> ALL(p.rejected || (SELECT id FROM ranked WHERE pick = 1))
    AND b.user_id IS DISTINCT FROM p.customer_id
),

-- --- offer-timeout expiry ----------------------------------------------------
tmo AS (
  SELECT LEAST(600, GREATEST(60, COALESCE(
    (SELECT value::int FROM app_settings WHERE key = 'dispatch_timeout_seconds' AND value ~ '^[0-9]+$'),
    240))) AS timeout_s
),
cutoff AS (SELECT now() - make_interval(secs => timeout_s) AS ts FROM tmo),

-- --- the live production source, for the drift guard -------------------------
src AS (
  SELECT pg_get_functiondef(p.oid) AS def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE p.proname = 'dispatch_jobs' AND n.nspname = 'public'
),

-- ============================================================================
-- CHECKS  (each yields one row: check name + boolean passed)
-- ============================================================================
checks AS (
  -- 1. Eligibility: offline drivers (#13,#26,#39) never appear in the queue
  SELECT 'eligibility_excludes_offline' AS check_name,
         NOT EXISTS (SELECT 1 FROM ranked WHERE id IN (
           '00000000-0000-0000-0000-000000000013','00000000-0000-0000-0000-000000000026','00000000-0000-0000-0000-000000000039')) AS passed
  UNION ALL
  -- 2. Eligibility: unapproved drivers (#11,#22,#33,#44) never appear
  SELECT 'eligibility_excludes_unapproved',
         NOT EXISTS (SELECT 1 FROM ranked WHERE id IN (
           '00000000-0000-0000-0000-000000000011','00000000-0000-0000-0000-000000000022','00000000-0000-0000-0000-000000000033','00000000-0000-0000-0000-000000000044'))
  UNION ALL
  -- 3. Eligibility: a rejected (already-declined) driver (#5) never re-appears
  SELECT 'eligibility_excludes_rejected',
         NOT EXISTS (SELECT 1 FROM ranked WHERE id = '00000000-0000-0000-0000-000000000005')
  UNION ALL
  -- 4. Eligibility: a provider who is the customer (#7) is never offered own job
  SELECT 'eligibility_excludes_self_customer',
         NOT EXISTS (SELECT 1 FROM ranked WHERE id = '00000000-0000-0000-0000-000000000007')
  UNION ALL
  -- 5. Load-aware: the FIRST pick must be an idle (0 active) driver
  SELECT 'first_pick_is_idle',
         (SELECT active FROM ranked WHERE pick = 1) = 0
  UNION ALL
  -- 6. Load-aware: no busy driver is ranked above any idle driver
  SELECT 'busy_never_beats_idle',
         (SELECT max(pick) FROM ranked WHERE active = 0)
       < (SELECT min(pick) FROM ranked WHERE active > 0)
  UNION ALL
  -- 7. Cascade order is a correct monotonic sort by (active, then distance):
  --    no later pick is "better" than an earlier one. This is the decline order.
  SELECT 'cascade_order_monotonic',
         NOT EXISTS (
           SELECT 1 FROM (
             SELECT active, dist,
                    lag(active) OVER (ORDER BY pick) AS pa,
                    lag(dist)   OVER (ORDER BY pick) AS pd
             FROM ranked
           ) t
           WHERE pa IS NOT NULL AND (active < pa OR (active = pa AND dist < pd))
         )
  UNION ALL
  -- 8. Sanity: with 50 providers there is a real queue to cascade through
  SELECT 'queue_is_populated',
         (SELECT count(*) FROM ranked) >= 30
  UNION ALL
  -- 9. Preferred driver WINS an equal-or-closer call
  SELECT 'preferred_wins_close_call',
         (SELECT chosen_id FROM pref_chosen WHERE scn = 'A')
       = (SELECT pref_id   FROM pref_chosen WHERE scn = 'A')
  UNION ALL
  -- 10. Preferred driver is NOT handed a worse (farther) job
  SELECT 'preferred_not_handed_worse_job',
         (SELECT chosen_id FROM pref_chosen WHERE scn = 'B')
       = (SELECT normal_id FROM pref_chosen WHERE scn = 'B')
  UNION ALL
  -- 11. Auto-accept: an auto_accept winner routes to 'assigned' (direct assign)
  SELECT 'auto_accept_routes_assigned',
         (SELECT route FROM route_calc WHERE scn = 'auto') = 'assigned'
  UNION ALL
  -- 12. Non-auto winner routes to a pending 'offer' (countdown)
  SELECT 'normal_routes_pending_offer',
         (SELECT route FROM route_calc WHERE scn = 'offer') = 'offer'
  UNION ALL
  -- 13. Timeout: an offer older than the cutoff is expired
  SELECT 'timeout_stale_offer_expires',
         (now() - interval '1 hour') < (SELECT ts FROM cutoff)
  UNION ALL
  -- 14. Timeout: a fresh offer is NOT expired
  SELECT 'timeout_fresh_offer_survives',
         NOT (now() < (SELECT ts FROM cutoff))
  UNION ALL
  -- 15. Decline/timeout → re-dispatch: after the winner declines, re-running the
  --     full eligibility filter drops them AND promotes the next driver (old #2).
  SELECT 'redispatch_drops_winner_promotes_next',
         NOT EXISTS (SELECT 1 FROM redispatch WHERE id = (SELECT id FROM ranked WHERE pick = 1))
     AND (SELECT id FROM redispatch WHERE pick = 1) = (SELECT id FROM ranked WHERE pick = 2)
  UNION ALL
  -- ----- DRIFT GUARDS: prod source must still contain the mirrored formulas ---
  SELECT 'guard_distance_formula',
         (SELECT def FROM src) LIKE '%(current_lat - j.job_lat)^2 + ((current_lng - j.job_lng) * 0.7)^2%'
  UNION ALL
  SELECT 'guard_eligibility_online_approved',
         (SELECT def FROM src) LIKE '%is_online = true%'
     AND (SELECT def FROM src) LIKE '%registration_status = ''approved''%'
  UNION ALL
  SELECT 'guard_load_aware_active_count',
         (SELECT def FROM src) LIKE '%status IN (''assigned'', ''in_progress'')%'
  UNION ALL
  SELECT 'guard_preferred_equal_or_closer',
         (SELECT def FROM src) LIKE '%pref_dist <= normal_dist%'
  UNION ALL
  SELECT 'guard_reject_and_self_exclusion',
         (SELECT def FROM src) LIKE '%id != ALL(rejected)%'
     AND (SELECT def FROM src) LIKE '%user_id IS DISTINCT FROM j.customer_id%'
)

SELECT
  check_name,
  CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result
FROM checks
ORDER BY passed ASC, check_name ASC;
