-- The storm-booking cron had been returning 401 every 30 minutes since it was
-- created, and nothing said so.
--
-- WHY IT WAS INVISIBLE: cron.job_run_details reported "succeeded" on every run,
-- because net.http_post succeeds when it QUEUES the request. The HTTP status
-- lands in net._http_response, which nothing watches. So the job looked healthy
-- while the response body was, every single time:
--   {"code":"UNAUTHORIZED_INVALID_JWT_FORMAT",
--    "message":"Auth header is not 'Bearer {token}'"}
--
-- WHY IT 401'd: the cron built its header as
--   'Bearer ' || coalesce(current_setting('app.service_role_key', true), '')
-- and `app.service_role_key` was never set — so it sent a bare "Bearer ".
-- It could not have been set: ALTER DATABASE ... SET on a custom parameter
-- requires superuser, which Supabase does not grant. The pattern was
-- unimplementable on this platform, not merely unconfigured.
--
-- CONSEQUENCE: storm bookings could never fire. Not "untested" — structurally
-- impossible. A customer who booked ahead in January would have had no charge,
-- no job, and no provider, while the booking sat "active" forever and the cron
-- reported success every half hour.
--
-- FIX: keep the key in Supabase Vault (encrypted at rest, and readable by the
-- cron) instead of a database parameter that cannot exist. Created out-of-band:
--   select vault.create_secret('<service_role_key>','service_role_key', ...);

-- Storm bookings: every 30 minutes, now with a real Authorization header.
select cron.unschedule('trigger-storm-bookings');
select cron.schedule(
  'trigger-storm-bookings',
  '*/30 * * * *',
  $cron$
  select net.http_post(
    url     := 'https://swttuujhcgpcsrxgupzv.supabase.co/functions/v1/trigger-storm-bookings',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' ||
                   (select decrypted_secret from vault.decrypted_secrets
                     where name = 'service_role_key')),
    body    := '{}'::jsonb);
  $cron$
);

-- dispatch_jobs() reads the same never-settable parameter for its two pushes
-- (auto-accept assignment and the pending-offer notification). Those calls have
-- kept working only because notify-provider and notify-dispatch are
-- verify_jwt=false, so the gateway never inspected the empty header — i.e. by
-- luck, not by design. Point it at the same Vault secret so the push path stops
-- depending on a function's auth setting never being tightened.
create or replace function public.dispatch_jobs_service_key()
returns text
language sql
stable
security definer
set search_path = public, vault
as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'
$$;

revoke all on function public.dispatch_jobs_service_key() from public, anon, authenticated;
