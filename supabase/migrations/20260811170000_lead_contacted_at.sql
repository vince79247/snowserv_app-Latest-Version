-- A lead card could say "contacted" but never WHEN.
--
-- Leads carry a status ('new' -> 'contacted' -> ...), and a status is not a
-- record: the actual question being asked of that card is "have I already
-- written to this person, and how long ago?". The green "Emailed <date>" chip
-- answers it from email_log — but email_log's oldest row is 2026-08-07, and
-- most of the early recruiting pipeline was worked before that, so those leads
-- showed a bare "contacted" with no date while newer ones showed a date. Same
-- shape as the providers.recruit_emailed_at gap fixed in 8936a22, one table
-- over.
alter table public.provider_leads
  add column if not exists contacted_at timestamptz;

comment on column public.provider_leads.contacted_at is
  'When this lead was FIRST moved off status=new. Set once and never '
  'overwritten by later status changes, or the date drifts to whenever the row '
  'was last touched. The lead equivalent of providers.recruit_emailed_at.';

-- Backfill from updated_at: the only thing that has ever written to a lead row
-- is the status change itself, so for an already-contacted lead updated_at IS
-- when it was contacted. Applied only where there is nothing better to use.
update public.provider_leads
set contacted_at = updated_at
where status is distinct from 'new' and contacted_at is null;
