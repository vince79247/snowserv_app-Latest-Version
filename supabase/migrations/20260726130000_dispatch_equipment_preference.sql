-- Qualification-based dispatch (#equipment, 2026-07-26). Adds an equipment SOFT
-- preference on top of the existing load-aware + preferred-driver logic:
--   * Jobs with a LARGE driveway (driveway_size = 'large') prefer motorized
--     providers (snowblower/plow, or legacy NULL). An EXPLICIT 'shovel' provider
--     is deprioritized for those jobs — pushed to the back of the ranking, NOT
--     excluded, so if a shovel-only provider is the only one online the job still
--     goes out (never stranded).
--   * SMALL driveways (a shovel handles those fine), and non-driveway jobs, are
--     unaffected — everyone is equally eligible. NULL size counts as "not large".
--   * The preferred-driver override won't send a large-driveway job to a
--     shovel-only preferred driver (equipment gate added to the preferred pick too).
-- Only three things change vs 20260713170000: (1) the queued-job loop also selects
-- `driveway_size`, (2) the normal-winner ORDER BY gets an equipment tiebreaker as
-- its FIRST key, (3) the preferred-driver query filters out shovel-only on large
-- driveways. Everything else (timeout, auto-accept, pushes) is byte-for-byte identical.
CREATE OR REPLACE FUNCTION dispatch_jobs()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  timeout_s int := LEAST(600, GREATEST(60, COALESCE(
    (SELECT value::int FROM app_settings
       WHERE key = 'dispatch_timeout_seconds' AND value ~ '^[0-9]+$'),
    240)));
  cutoff TIMESTAMPTZ := NOW() - make_interval(secs => timeout_s);
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
  svc_key text := current_setting('app.service_role_key', true);
BEGIN
  -- Expire timed-out dispatches: add provider to rejected list, clear dispatch fields
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
    -- LARGE-driveway jobs), then fewest active jobs, then nearest.
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
    ORDER BY
      -- Equipment soft preference: 1 (last) only for a shovel-only provider on a
      -- LARGE-driveway job; 0 otherwise. NULL/snowblower/plow are never penalized,
      -- and small/unknown-size driveways never penalize anyone.
      (CASE WHEN j.driveway_size = 'large' AND equipment = 'shovel'
            THEN 1 ELSE 0 END) ASC,
      (SELECT count(*) FROM jobs aj
         WHERE aj.provider_id = providers.id
           AND aj.status IN ('assigned', 'in_progress')) ASC,
      CASE
        WHEN j.job_lat IS NOT NULL AND j.job_lng IS NOT NULL
        THEN (current_lat - j.job_lat)^2 + ((current_lng - j.job_lng) * 0.7)^2
        ELSE 0
      END ASC
    LIMIT 1;

    -- No eligible provider at all → leave the job queued for the next tick.
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
$$;
