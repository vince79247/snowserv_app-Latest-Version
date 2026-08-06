-- Records when an admin last sent a provider a recruiting / finish-your-registration
-- email.
--
-- A signup stuck at registration_status='incomplete' is a recruiting lead, but it
-- has no provider_leads row, so there was no status to set and nothing on screen
-- said whether it had been worked. Vince emailed the same stalled signup twice in
-- a row because the first send silently failed and there was no way to tell.
alter table public.providers
  add column if not exists recruit_emailed_at timestamptz;

comment on column public.providers.recruit_emailed_at is
  'When an admin last sent this provider a recruiting/finish-your-registration email. Prevents silently emailing a stalled signup twice.';
