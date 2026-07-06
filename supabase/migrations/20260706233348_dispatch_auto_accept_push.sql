-- Close the auto-accept push gap: when the CRON auto-assigns a job (e.g. a
-- re-dispatch to an auto-accept provider whose app is closed), notify them via
-- pg_net -> notify-provider, the same way the payout cron calls process-payout.
-- The push is best-effort and wrapped so it can never break dispatch.
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
        -- Best-effort push so a closed-app provider still gets alerted.
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
          NULL; -- never let a push failure abort dispatch
        END;
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
