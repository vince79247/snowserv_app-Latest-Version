-- Seven-year retention purge — makes good on a promise we already published.
--
-- website/delete-account.html tells the public, and Google Play's Data safety
-- declaration links that page as our delete-data URL:
--
--   "Scrubbed job and payment records are retained for seven (7) years from the
--    date of the job ... after which they are deleted."
--
-- The RETAIN half happened by default (doing nothing keeps rows forever). The
-- DELETE half had nothing behind it. That is the gap this closes: not a risk of
-- losing records we must keep, but of still holding records in 2035 that we said
-- publicly we would delete in 2033.
--
-- Why seven and not three (checked 2026-08-11):
--   * NY Tax Law § 1135 requires sales-tax records be preserved THREE years, with
--     the Department able to demand longer.
--   * IRS baseline is three, stretching to six for a substantial understatement.
-- Seven is the conservative bookkeeping convention and is longer than either
-- floor, so purging on this schedule cannot delete something a taxing authority
-- could still ask for. If the number ever changes, change it HERE and on the
-- public page in the same commit — they are one promise in two places.

-- ---------------------------------------------------------------------------
-- Order of deletion is dictated by the foreign keys, which were inspected rather
-- than assumed:
--   disputes.job_id        -> NO ACTION  (blocks the job delete; must go FIRST)
--   storm_bookings.job_id  -> SET NULL   (handles itself)
--   jobs.address_id        -> NO ACTION  (so addresses only after their jobs)
--   address_notes.address_id / storm_bookings.address_id -> CASCADE
-- ---------------------------------------------------------------------------

create or replace function public.purge_expired_records()
returns table (jobs_deleted integer, disputes_deleted integer, addresses_deleted integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  -- Anchored on jobs.created_at because the published wording is "from the date
  -- of the job", and created_at is the one timestamp every row has.
  cutoff      timestamptz := now() - interval '7 years';
  d_disputes  integer := 0;
  d_jobs      integer := 0;
  d_addresses integer := 0;
begin
  with gone as (
    delete from public.disputes d
    using public.jobs j
    where d.job_id = j.id
      and j.created_at < cutoff
    returning d.id
  )
  select count(*) into d_disputes from gone;

  with gone as (
    delete from public.jobs
    where created_at < cutoff
    returning id
  )
  select count(*) into d_jobs from gone;

  -- Addresses are deliberately the most cautious step. An address is only removed
  -- when NOTHING references it any more AND its owner is already gone. A live
  -- customer's saved address must never be swept up just because their oldest job
  -- aged out — that would silently break the account of someone still ordering.
  with gone as (
    delete from public.addresses a
    where not exists (select 1 from public.jobs j where j.address_id = a.id)
      and not exists (select 1 from public.users u where u.id = a.user_id)
    returning a.id
  )
  select count(*) into d_addresses from gone;

  return query select d_jobs, d_disputes, d_addresses;
end;
$$;

comment on function public.purge_expired_records() is
  'Deletes jobs (and their disputes) older than seven years, then any address left '
  'with no jobs and no owner. Implements the retention promise published at '
  'https://snowserv.app/delete-account. Runs monthly via pg_cron.';

revoke all on function public.purge_expired_records() from public, anon, authenticated;

-- Monthly, not daily: the cutoff moves by a day at a time, so there is nothing a
-- daily run would catch that the 1st of the month does not. 03:20 UTC on the 1st
-- keeps it clear of the every-minute dispatch cron.
select cron.unschedule('purge-expired-records')
where exists (select 1 from cron.job where jobname = 'purge-expired-records');

select cron.schedule(
  'purge-expired-records',
  '20 3 1 * *',
  $cron$ select public.purge_expired_records(); $cron$
);
