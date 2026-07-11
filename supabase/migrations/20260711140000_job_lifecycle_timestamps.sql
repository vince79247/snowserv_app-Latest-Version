-- Record the provider job-lifecycle timestamps for the admin panel (disputes,
-- payroll, response-time metrics): when the driver ACCEPTED, STARTED, and
-- FINISHED. Previously only created_at (ordered) and dispatched_at (offered)
-- existed, so start/finish times were thrown away.
--
-- Stamped by a BEFORE UPDATE trigger using the DB clock (now()), NOT the client
-- — so they're correct regardless of any device's clock (we've been bitten by
-- emulator clock skew) and they fire for EVERY path that changes status: the
-- client accept/start/complete, claim-from-board, and the SQL auto-accept inside
-- dispatch_jobs(). Set only on the transition INTO each state.

ALTER TABLE jobs ADD COLUMN IF NOT EXISTS accepted_at  timestamptz;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS started_at   timestamptz;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS completed_at timestamptz;

CREATE OR REPLACE FUNCTION set_job_status_timestamps()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = 'assigned'    AND OLD.status IS DISTINCT FROM 'assigned'    THEN
    NEW.accepted_at = now();
  END IF;
  IF NEW.status = 'in_progress' AND OLD.status IS DISTINCT FROM 'in_progress' THEN
    NEW.started_at = now();
  END IF;
  IF NEW.status = 'completed'   AND OLD.status IS DISTINCT FROM 'completed'   THEN
    NEW.completed_at = now();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_job_status_timestamps ON jobs;
CREATE TRIGGER trg_job_status_timestamps
  BEFORE UPDATE ON jobs
  FOR EACH ROW
  EXECUTE FUNCTION set_job_status_timestamps();
