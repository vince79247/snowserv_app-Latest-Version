-- Optional "before" photos captured when the provider taps Start Job (#19/#11
-- follow-up). Kept SEPARATE from completion_photos (the "after" shots shown to
-- the customer on their receipt) so the admin can show a clean before/after
-- pair and the customer receipt stays "after only". Camera-only, and OPTIONAL:
-- the provider can Skip, and a failed upload never blocks Start (which captures
-- the customer's card). Public URLs in the job-photos bucket, same as after.
alter table public.jobs add column if not exists before_photos text[];

comment on column public.jobs.before_photos is
  'Optional provider "before" photos (job-photos public URLs) taken at Start. Proof-of-work / dispute shield. May be empty/null.';
