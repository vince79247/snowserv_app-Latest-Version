-- Storm-window alerts, checked every 3 hours.
--
-- Every 3h rather than daily because a forecast firms up through the day and a
-- storm can appear inside the 72h window between two daily checks. Repeats are
-- not a risk: storm_alerts holds one row per (zone, storm date), so a provider
-- hears about a given storm once however often this runs.
--
-- Not every minute either — a push that arrives repeatedly is a push people
-- turn off, and the one night it matters is the night they would have missed.
SELECT cron.unschedule('storm-alert')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'storm-alert');

SELECT cron.schedule(
  'storm-alert',
  '15 */3 * * *',
  $cron$
  select net.http_post(
    url     := 'https://swttuujhcgpcsrxgupzv.supabase.co/functions/v1/storm-alert',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || public.dispatch_jobs_service_key()
               ),
    body    := '{}'::jsonb
  );
  $cron$
);
