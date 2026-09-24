-- One pending offer per provider at a time.
--
-- THE BUG (found 2026-09-24 while planning a 100-customer load test):
-- dispatch_jobs() ranks providers partly by "fewest active jobs", counting
--   jobs.provider_id = <them> AND status IN ('assigned','in_progress')
-- A PENDING OFFER is neither: it is status='requested' with dispatched_to set.
-- So an outstanding offer was invisible to the load ranking.
--
-- The dispatcher loops over every queued job in ONE tick, and offering job #1
-- to somebody changes nothing the ranking reads — dispatched_to is not
-- provider_id, and the status stays 'requested'. So job #2 evaluated
-- identically and picked the same winner. And #3. And #100.
--
-- Result on a storm night: 100 orders became 100 simultaneous offers on ONE
-- provider's phone, each with its own dispatch_timeout_seconds countdown. They
-- can accept exactly one; the other 99 expire together, which adds that
-- provider to all 99 jobs' rejected_providers, and the whole clump cascades
-- onto the next provider at once. Jobs moved as a stampede instead of
-- spreading out.
--
-- Auto-accept providers were never affected: that path sets status='assigned'
-- AND provider_id, which the load count does see. It was specifically the
-- normal tap-to-accept flow that had the blind spot.
--
-- THE FIX: a provider can only act on one offer at a time, so skip anyone who
-- is already holding one. Remaining jobs stay queued and go out as each
-- provider clears theirs — a queue instead of a stampede. Applied to BOTH the
-- normal winner and the preferred-driver override, for the same reason.
--
-- Note the ordering inside the function is load-bearing and unchanged: the
-- expiry loop runs FIRST, so a provider sitting on a timed-out offer is freed
-- before this exclusion is evaluated and cannot be locked out by a stale one.
--
-- ⚠️ Trade-off, accepted deliberately: with only one online provider, jobs now
-- go out one per dispatch tick (the cron runs every minute) instead of all at
-- once. That is the point. It does mean a provider who accepts instantly waits
-- up to ~60s for the next offer. If that ever matters, the answer is to call
-- dispatch_jobs() on accept — NOT to relax this.

CREATE OR REPLACE FUNCTION public.dispatch_jobs()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  timeout_s int := LEAST(600, GREATEST(60, COALESCE(
    (SELECT value::int FROM app_settings
       WHERE key = 'dispatch_timeout_seconds' AND value ~ '^[0-9]+$'),
    240)));
  cutoff TIMESTAMPTZ := NOW() - make_interval(secs => timeout_s);
  -- Distance is compared as squared degrees: (dlat)^2 + (dlng*0.7)^2. One
  -- degree of latitude is ~69 miles, so a ~2-mile band is (2/69)^2 ≈ 0.00084.
  -- Drivers inside the same band count as "equally close" and are then ranked
  -- by rating; the exact distance still breaks ties inside a band.
  dist_band double precision := 0.00084;
  j RECORD;
  rejected uuid[];
  normal_id uuid;
  normal_auto boolean;
  normal_dist double precision;
  pref_id uuid;
  pref_auto boolean;
  pref_dist double precision;
  chosen_id uuid;
  chosen_auto boolean;
  svc_key text := public.dispatch_jobs_service_key();
BEGIN
  -- Expire timed-out dispatches: add provider to rejected list, clear dispatch
  -- fields. MUST stay first — it is what releases a provider who is holding a
  -- dead offer, so the "already holding an offer" exclusion below never locks
  -- somebody out permanently.
  FOR j IN
    SELECT id, dispatched_to, rejected_providers
    FROM jobs
    WHERE status = 'requested'
      AND dispatched_to IS NOT NULL
      AND dispatched_at < cutoff
  LOOP
    UPDATE jobs SET
      dispatched_to   = NULL,
      dispatched_at   = NULL,
      rejected_providers = COALESCE(j.rejected_providers, ARRAY[]::uuid[]) || j.dispatched_to
    WHERE id = j.id;
  END LOOP;

  -- Dispatch all jobs that have no assigned provider
  FOR j IN
    SELECT id, job_lat, job_lng, rejected_providers, customer_id, driveway_size
    FROM jobs
    WHERE status = 'requested'
      AND dispatched_to IS NULL
  LOOP
    rejected := COALESCE(j.rejected_providers, ARRAY[]::uuid[]);

    -- Normal winner: equipment-capable first (shovel-only pushed back ONLY on
    -- LARGE-driveway jobs), then fewest active jobs, then nearest BAND, then
    -- best rated within that band, then genuinely nearest.
    SELECT id, auto_accept,
      CASE
        WHEN j.job_lat IS NOT NULL AND j.job_lng IS NOT NULL
        THEN (current_lat - j.job_lat)^2 + ((current_lng - j.job_lng) * 0.7)^2
        ELSE 0
      END
    INTO normal_id, normal_auto, normal_dist
    FROM providers
    WHERE is_online = true
      AND registration_status = 'approved'
      AND id != ALL(rejected)
      AND user_id IS DISTINCT FROM j.customer_id
      -- Suspended people do not get work. Checked here rather than trusted to
      -- the client, so it holds however the job was created.
      AND NOT EXISTS (
        SELECT 1 FROM users u
        WHERE u.id = providers.user_id AND u.is_suspended = true
      )
      -- Already holding a pending offer → not eligible for another. They can
      -- only tap Accept on one, and without this every job in the batch picked
      -- the same person (see the header comment).
      AND NOT EXISTS (
        SELECT 1 FROM jobs pj
        WHERE pj.dispatched_to = providers.id
          AND pj.status = 'requested'
      )
    ORDER BY
      -- Equipment soft preference: 1 (last) only for a shovel-only provider on a
      -- LARGE-driveway job; 0 otherwise. NULL/snowblower/plow are never penalized,
      -- and small/unknown-size driveways never penalize anyone.
      (CASE WHEN j.driveway_size = 'large' AND equipment = 'shovel'
            THEN 1 ELSE 0 END) ASC,
      (SELECT count(*) FROM jobs aj
         WHERE aj.provider_id = providers.id
           AND aj.status IN ('assigned', 'in_progress')) ASC,
      -- Distance BAND, so "about as close" drivers compete on rating.
      (CASE
        WHEN j.job_lat IS NOT NULL AND j.job_lng IS NOT NULL
        THEN floor((((current_lat - j.job_lat)^2 + ((current_lng - j.job_lng) * 0.7)^2)) / dist_band)
        ELSE 0
      END) ASC,
      COALESCE(rating, 5) DESC,
      CASE
        WHEN j.job_lat IS NOT NULL AND j.job_lng IS NOT NULL
        THEN (current_lat - j.job_lat)^2 + ((current_lng - j.job_lng) * 0.7)^2
        ELSE 0
      END ASC
    LIMIT 1;

    -- No eligible provider at all → leave the job queued for the next tick.
    -- This is now also the "everyone online is already holding an offer" case,
    -- which is exactly the queueing behaviour we want.
    IF normal_id IS NULL THEN
      CONTINUE;
    END IF;

    -- Nearest eligible PREFERRED driver whose override is still live, with a
    -- known location (need it to compare distance). Requires a job location too.
    -- A shovel-only preferred driver is not eligible for a LARGE-driveway job.
    pref_id := NULL;
    IF j.job_lat IS NOT NULL AND j.job_lng IS NOT NULL THEN
      SELECT id, auto_accept,
        (current_lat - j.job_lat)^2 + ((current_lng - j.job_lng) * 0.7)^2
      INTO pref_id, pref_auto, pref_dist
      FROM providers
      WHERE is_online = true
        AND registration_status = 'approved'
        AND id != ALL(rejected)
        AND user_id IS DISTINCT FROM j.customer_id
        AND preferred_until IS NOT NULL
        AND preferred_until > now()
        AND current_lat IS NOT NULL
        AND current_lng IS NOT NULL
        AND NOT (j.driveway_size = 'large' AND equipment = 'shovel')
        -- The preferred-driver override is a convenience lever, not an
        -- exemption from being suspended.
        AND NOT EXISTS (
          SELECT 1 FROM users u
          WHERE u.id = providers.user_id AND u.is_suspended = true
        )
        -- Nor an exemption from one-offer-at-a-time. A preferred driver who is
        -- already deciding on a job is not a better home for another one.
        AND NOT EXISTS (
          SELECT 1 FROM jobs pj
          WHERE pj.dispatched_to = providers.id
            AND pj.status = 'requested'
        )
      ORDER BY (current_lat - j.job_lat)^2 + ((current_lng - j.job_lng) * 0.7)^2 ASC
      LIMIT 1;
    END IF;

    -- Preferred driver wins ONLY if equal-or-closer than the normal winner.
    IF pref_id IS NOT NULL AND pref_dist <= normal_dist THEN
      chosen_id := pref_id;
      chosen_auto := pref_auto;
    ELSE
      chosen_id := normal_id;
      chosen_auto := normal_auto;
    END IF;

    IF chosen_auto THEN
      -- Provider is on auto-accept: assign directly, skip the offer step.
      UPDATE jobs SET
        status        = 'assigned',
        provider_id   = chosen_id,
        dispatched_to = NULL,
        dispatched_at = NULL
      WHERE id = j.id;
      BEGIN
        PERFORM net.http_post(
          url := 'https://swttuujhcgpcsrxgupzv.supabase.co/functions/v1/notify-provider',
          headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || COALESCE(svc_key, '')
          ),
          body := jsonb_build_object('job_id', j.id, 'status', 'auto_assigned')
        );
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    ELSE
      UPDATE jobs SET
        dispatched_to = chosen_id,
        dispatched_at = NOW()
      WHERE id = j.id;
      -- PENDING OFFER push: tell the offered provider a job is waiting.
      BEGIN
        PERFORM net.http_post(
          url := 'https://swttuujhcgpcsrxgupzv.supabase.co/functions/v1/notify-dispatch',
          headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || COALESCE(svc_key, '')
          ),
          body := jsonb_build_object('job_id', j.id)
        );
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END IF;
  END LOOP;
END;
$function$;
