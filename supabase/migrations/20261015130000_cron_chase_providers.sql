-- Nightly provider chaser. Runs 14:00 UTC = 10am EDT / 9am EST — a civil hour
-- for the recipient either side of the daylight-saving switch.
--
-- Daily looks aggressive but is not: chase-providers enforces a 30-day quiet
-- period per person (Vince's rule, "we can pester them once a month"), a
-- lifetime cap of 4 contacts, and skips accounts older than 120 days with no
-- progress. Most days it will send nothing. What daily buys is that somebody
-- who goes quiet is noticed within a day instead of whenever a human looks —
-- Isaiah sat approved-and-unable-to-work for ten weeks because nobody did.
--
-- Uses dispatch_jobs_service_key(), the SAME helper the dispatch and payout
-- crons use. ⚠️ That returns the `sb_secret_` key, which is what edge functions
-- see in SUPABASE_SERVICE_ROLE_KEY. The legacy `service_role` JWT also listed in
-- the dashboard is NOT the same string and will 401 here — that mismatch cost a
-- debugging round on 2026-10-15 and is the same family as the storm-booking
-- cron that 401'd silently for months (reference-pg-cron-silent-401).
SELECT cron.unschedule('chase-providers')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'chase-providers');

SELECT cron.schedule(
  'chase-providers',
  '0 14 * * *',
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
