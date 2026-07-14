-- Capture-failure visibility (QA punchlist #9). When a provider taps Start Job,
-- markInProgress captures the customer's held payment. That call used to be
-- swallowed on failure (debugPrint only) — so if the capture failed, the
-- provider still worked, the job still completed, the customer was never charged,
-- and nobody knew. These columns make a failed capture LOUD: the job is flagged,
-- the provider is told (non-blocking), and the admin panel surfaces it with a
-- "Retry capture" button. Cleared once a (re)capture succeeds.
alter table public.jobs add column if not exists capture_failed boolean not null default false;
alter table public.jobs add column if not exists capture_error text;

comment on column public.jobs.capture_failed is
  'True if capturing the customer payment at Start failed and still needs resolving. Cleared on a successful (re)capture.';
