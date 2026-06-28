-- Daily payout batch: calls process-payout for every completed job older than 7 days
-- Run this once in the Supabase SQL editor (after dispatch_jobs_cron.sql)

CREATE OR REPLACE FUNCTION trigger_pending_payouts()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  j RECORD;
BEGIN
  FOR j IN
    SELECT id
    FROM jobs
    WHERE status = 'completed'
      AND payout_status = 'pending'
      AND created_at < NOW() - INTERVAL '7 days'
  LOOP
    PERFORM net.http_post(
      url := 'https://swttuujhcgpcsrxgupzv.supabase.co/functions/v1/process-payout',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || current_setting('app.service_role_key')
      ),
      body := jsonb_build_object('job_id', j.id)
    );
  END LOOP;
END;
$$;

-- Run once per day at 2am UTC
SELECT cron.schedule('payout-batch', '0 2 * * *', 'SELECT trigger_pending_payouts()');
