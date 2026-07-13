-- Location verification for the provider workflow (QA punchlist #19).
-- When a provider taps "Start Job" and "Complete Job", the app measures how far
-- their phone GPS is from the job's geocoded address and records the distance in
-- METERS here. This is a VERIFY-not-GATE signal: the required live completion
-- photo is the primary proof of work, so a null (location denied / no GPS fix /
-- job never geocoded) never blocks the provider — it just surfaces as
-- "location unverified" on the admin job card for a human to eyeball before the
-- weekly payout. A large distance surfaces as "off-site (Xkm away)".
--   * NULL  -> couldn't measure (unverified)
--   * small -> on-site (green)
--   * large -> off-site (amber warning)
alter table public.jobs add column if not exists start_distance_m numeric;
alter table public.jobs add column if not exists complete_distance_m numeric;

comment on column public.jobs.start_distance_m is
  'Meters between provider GPS and job address when Start Job was tapped. NULL = unverified.';
comment on column public.jobs.complete_distance_m is
  'Meters between provider GPS and job address when Complete Job was tapped. NULL = unverified.';
