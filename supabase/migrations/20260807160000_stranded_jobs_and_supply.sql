-- 1. A job nobody accepts must not queue forever.
--
-- Found in the 2026-08-07 full-app scan. dispatch_jobs() hits
-- `IF normal_id IS NULL THEN CONTINUE` when no provider is eligible, so the job
-- sits at 'requested' indefinitely. Meanwhile:
--   * the customer watches "Searching for a provider near you" with a HOLD on
--     their card and is never told anything changed;
--   * Stripe cancels an uncaptured authorization after ~7 days, so if somebody
--     finally accepts on day 8, capture-payment fails against a dead
--     PaymentIntent and the work gets done for nothing;
--   * nobody — customer or admin — is alerted at any point.
--
-- With 3 approved providers and 0 online at the time of writing, this is the
-- DEFAULT path at launch, not an edge case.
--
-- Two stages, both tunable from app_settings:
--   NUDGE  (default 20 min)  — tell the customer honestly that it's taking a
--                              while and that they can cancel for a full refund.
--                              Once only; stranded_notified_at is the latch.
--   GIVE UP (default 360 min) — cancel the job and RELEASE THE HOLD rather than
--                              let it rot until Stripe kills it. Better to hand
--                              the money back with an apology than to keep it
--                              against work we could not deliver.
--
-- Deliberately NOT auto-cancelling early: a provider coming online at hour two
-- is a normal storm pattern, and cancelling a job we could still serve costs a
-- customer. Six hours is long enough to be sure, and far short of the 7-day
-- authorization limit.

alter table public.jobs
  add column if not exists stranded_notified_at timestamptz;

comment on column public.jobs.stranded_notified_at is
  'When we told the customer their job is taking longer than usual to place. Latch so expire_stranded_jobs() nudges once, not every minute.';

insert into public.app_settings (key, value)
values ('stranded_nudge_minutes', '20')
on conflict (key) do nothing;

insert into public.app_settings (key, value)
values ('stranded_giveup_minutes', '360')
on conflict (key) do nothing;

create or replace function public.expire_stranded_jobs()
returns void
language plpgsql
security definer
as $function$
declare
  nudge_m  int := greatest(5, coalesce((select value::int from app_settings
              where key = 'stranded_nudge_minutes' and value ~ '^[0-9]+$'), 20));
  giveup_m int := greatest(30, coalesce((select value::int from app_settings
              where key = 'stranded_giveup_minutes' and value ~ '^[0-9]+$'), 360));
  j record;
  svc_key text := current_setting('app.service_role_key', true);
begin
  -- STAGE 1 — nudge. Never accepted, never even offered to anyone, and older
  -- than the nudge window.
  for j in
    select id from jobs
     where status = 'requested'
       and provider_id is null
       and stranded_notified_at is null
       and created_at < now() - make_interval(mins => nudge_m)
  loop
    update jobs set stranded_notified_at = now() where id = j.id;
    begin
      perform net.http_post(
        url := 'https://swttuujhcgpcsrxgupzv.supabase.co/functions/v1/notify-customer',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || coalesce(svc_key, '')),
        body := jsonb_build_object('job_id', j.id, 'status', 'still_searching'));
    exception when others then
      -- A failed push must never stop us from latching, or we'd re-notify every
      -- minute forever.
      null;
    end;
  end loop;

  -- STAGE 2 — give up and hand the money back. refund-job RELEASES an
  -- uncaptured hold (nothing was ever charged), so this costs the customer
  -- nothing and frees the funds on their card immediately.
  for j in
    select id from jobs
     where status = 'requested'
       and provider_id is null
       and created_at < now() - make_interval(mins => giveup_m)
  loop
    begin
      perform net.http_post(
        url := 'https://swttuujhcgpcsrxgupzv.supabase.co/functions/v1/refund-job',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || coalesce(svc_key, '')),
        body := jsonb_build_object('job_id', j.id));
    exception when others then null;
    end;

    update jobs set status = 'cancelled' where id = j.id;

    begin
      perform net.http_post(
        url := 'https://swttuujhcgpcsrxgupzv.supabase.co/functions/v1/notify-customer',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || coalesce(svc_key, '')),
        body := jsonb_build_object('job_id', j.id, 'status', 'no_provider_found'));
    exception when others then null;
    end;
  end loop;
end;
$function$;

-- Runs on the same minute tick as dispatch. Cheap: both loops are indexed on
-- status and almost always return zero rows.
select cron.schedule('expire-stranded-jobs', '* * * * *',
  $$select public.expire_stranded_jobs();$$);


-- 2. Let a customer see whether anyone is actually available BEFORE they pay.
--
-- There was no supply check at order time: you could pay at 3am with zero
-- providers online and get no hint anything was wrong. RLS (correctly) stops a
-- customer reading the providers table, so this is a SECURITY DEFINER function
-- that returns a COUNT and nothing else — no names, no locations, no rows.
--
-- "Available" mirrors what dispatch_jobs will actually consider: approved AND
-- online. payouts_enabled is included because a provider who can't be paid
-- can't go online any more either, so counting them would overstate supply.
create or replace function public.available_provider_count()
returns int
language sql
security definer
set search_path to 'public'
stable
as $function$
  select count(*)::int from providers
   where registration_status = 'approved'
     and is_online = true
     and payouts_enabled = true;
$function$;

revoke all on function public.available_provider_count() from public;
grant execute on function public.available_provider_count() to authenticated, anon;


-- 3. Drop the three dead tables found in the same scan.
--
-- payouts / payments / job_photos: all empty, RLS-enabled with zero policies,
-- and nothing in the app or any edge function reads or writes them. Payout
-- state actually lives on jobs.payout_status; completion photos live in the
-- job-photos STORAGE bucket and jobs.completion_photos[].
--
-- Dropping them so nobody wires new code to a table that was never wired up —
-- an empty table with a plausible name is a trap.
drop table if exists public.payouts;
drop table if exists public.payments;
drop table if exists public.job_photos;
