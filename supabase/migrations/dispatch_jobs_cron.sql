-- Server-side waterfall dispatch
-- Run this once in the Supabase SQL editor

-- Step 1: Create the dispatch function
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

    SELECT id INTO p
    FROM providers
    WHERE is_online = true
      AND registration_status = 'approved'
      AND id != ALL(rejected)
    ORDER BY
      CASE
        WHEN j.job_lat IS NOT NULL AND j.job_lng IS NOT NULL
        THEN (current_lat - j.job_lat)^2 + ((current_lng - j.job_lng) * 0.7)^2
        ELSE 0
      END
    LIMIT 1;

    IF FOUND THEN
      UPDATE jobs SET
        dispatched_to = p.id,
        dispatched_at = NOW()
      WHERE id = j.id;
    END IF;
  END LOOP;
END;
$$;

-- Step 2: Schedule it to run every minute (requires pg_cron extension)
-- pg_cron is enabled by default on Supabase
SELECT cron.schedule('dispatch-jobs', '* * * * *', 'SELECT dispatch_jobs()');
