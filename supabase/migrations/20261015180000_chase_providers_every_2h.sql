-- Re-schedule the chaser from daily to every 2 hours.
--
-- It now also handles WEBSITE LEADS, and a fresh lead is the hottest thing in
-- the pipeline — a daily pass meant somebody who filled in the form at 3pm
-- waited until 10am the next day. Frequency costs nothing on the provider side:
-- those nudges are guarded by a 30-day quiet period and a 4-contact lifetime
-- cap, so running more often cannot turn into nagging.
SELECT cron.unschedule('chase-providers')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'chase-providers');

SELECT cron.schedule(
  'chase-providers',
  '30 */2 * * *',
  $cron$
  select net.http_post(
    url     := 'https://swttuujhcgpcsrxgupzv.supabase.co/functions/v1/chase-providers',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || public.dispatch_jobs_service_key()
               ),
    body    := '{}'::jsonb
  );
  $cron$
);
