-- Update the server-side dispatch cron (runs every minute) to match the client:
--   1. LOAD-AWARE: rank candidates by fewest active jobs first, then proximity
--      (was distance-only), so no provider hoards the queue.
--   2. AUTO-ACCEPT: if the chosen provider has auto_accept on, assign the job
--      directly (status=assigned) instead of leaving it as a pending offer.
-- Only the function body is replaced; the existing cron.schedule('dispatch-jobs')
-- keeps calling it. Expire logic + rejected/uuid handling preserved as-is.
CREATE OR REPLACE FUNCTION dispatch_jobs()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  cutoff TIMESTAMPTZ := NOW() - INTERVAL '3 minutes';
  j RECORD;
  p RECORD;
  rejected TEXT[];
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

    -- Load-aware pick: fewest active jobs first, then nearest.
    SELECT id, auto_accept INTO p
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

    IF FOUND THEN
      IF p.auto_accept THEN
        -- Provider is on auto-accept: assign directly, skip the offer step.
        UPDATE jobs SET
          status        = 'assigned',
          provider_id   = p.id,
          dispatched_to = NULL,
          dispatched_at = NULL
        WHERE id = j.id;
      ELSE
        UPDATE jobs SET
          dispatched_to = p.id,
          dispatched_at = NOW()
        WHERE id = j.id;
      END IF;
    END IF;
  END LOOP;
END;
$$;
