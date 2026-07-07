-- Indexes on the hot query paths. The dispatch cron runs every minute and the
-- app filters jobs by these columns constantly (load-aware count, active jobs,
-- my orders, dispatched offers, provider lookup). Tiny table today, but cheap
-- insurance before real volume — especially during storm bursts.
create index if not exists idx_jobs_status          on jobs (status);
create index if not exists idx_jobs_provider_status on jobs (provider_id, status);
create index if not exists idx_jobs_customer        on jobs (customer_id);
create index if not exists idx_jobs_dispatched_to   on jobs (dispatched_to);
create index if not exists idx_providers_user       on providers (user_id);
