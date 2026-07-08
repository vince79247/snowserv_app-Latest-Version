-- ROOT-CAUSE FIX for "no push on new job offers".
--
-- Since the Stripe Checkout migration, jobs are created by the stripe-webhook,
-- which kicks dispatch via the dispatch_jobs() RPC. dispatch_jobs() pushed a
-- notification ONLY on the auto-accept branch (notify-provider / auto_assigned).
-- For a normal PENDING OFFER (auto_accept = false) it set dispatched_to and sent
-- nothing — so the provider saw the job card appear via Realtime but never got a
-- push. (The only caller of notify-dispatch was the CLIENT dispatcher in
-- lib/utils/dispatch.dart, which is NOT in the webhook path.)
--
-- Fix: after setting a pending offer, fire notify-dispatch via pg_net — the same
-- net.http_post + app.service_role_key pattern already used for auto_assigned.
-- This also means an expired offer that re-dispatches to the NEXT provider now
-- pushes them too (previously silent). Everything else is unchanged.

CREATE OR REPLACE FUNCTION dispatch_jobs()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  cutoff TIMESTAMPTZ := NOW() - INTERVAL '3 minutes';
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
    SELECT id, job_lat, job_lng, rejected_providers
    FROM jobs
    WHERE status = 'requested'
      AND dispatched_to IS NULL
  LOOP
    rejected := COALESCE(j.rejected_providers, ARRAY[]::uuid[]);

    -- Normal winner: fewest active jobs, then nearest (no preference).
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
    ORDER BY
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
    pref_id := NULL;
    IF j.job_lat IS NOT NULL AND j.job_lng IS NOT NULL THEN
      SELECT id, auto_accept,
        (current_lat - j.job_lat)^2 + ((current_lng - j.job_lng) * 0.7)^2
      INTO pref_id, pref_auto, pref_dist
      FROM providers
      WHERE is_online = true
        AND registration_status = 'approved'
        AND id != ALL(rejected)
        AND preferred_until IS NOT NULL
        AND preferred_until > now()
        AND current_lat IS NOT NULL
        AND current_lng IS NOT NULL
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
            'Authorization', 'Bearer ' || current_setting('app.service_role_key')
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
      -- PENDING OFFER push (the fix): tell the offered provider a job is waiting.
      BEGIN
        PERFORM net.http_post(
          url := 'https://swttuujhcgpcsrxgupzv.supabase.co/functions/v1/notify-dispatch',
          headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || current_setting('app.service_role_key')
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
