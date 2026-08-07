-- 1. ANY government photo ID, not specifically a driver's license.
--
-- Vince: "why do we even need their driver license? There are so many people
-- who drive without a valid license. It's not our problem. Why don't we just
-- ask them for a government issued ID? We can capture so many more people."
--
-- He's right, and the requirement was never thought through. What the document
-- is actually FOR is confirming this is a real, identifiable adult before we
-- send them to a stranger's house. A state ID card, passport, permanent
-- resident card or military ID all prove that exactly as well as a license
-- does. Demanding a license specifically excludes shovel crews who don't drive,
-- anyone whose license has lapsed, and anyone who simply doesn't have one —
-- for no gain, because we're not the DMV and whether someone may legally drive
-- is between them and the state.
--
-- It's also duplicated work: Stripe Connect runs real KYC identity verification
-- before it will pay anyone, to a financial-regulation standard we cannot match
-- by eyeballing a photo. Our copy is the weaker of the two.
--
-- The dl_* COLUMNS keep their names on purpose. Renaming them would break
-- build 16, which is on TestFlight and on Vince's phone right now, the moment
-- it wrote a registration. Tidier column names are not worth a broken install.
comment on column public.providers.dl_number is
  'Number from ANY government photo ID (see id_type) - not necessarily a driver license. Column name is historical; renaming it would break shipped builds.';
comment on column public.providers.dl_state is
  'Issuing state for the photo ID. Blank for a passport, which has no state.';
comment on column public.providers.dl_photo_url is
  'Storage PATH (private bucket) of the government photo ID image.';

alter table public.providers
  add column if not exists id_type text;

comment on column public.providers.id_type is
  'Which government photo ID was supplied: drivers_license | state_id | passport | permanent_resident | military_id.';

-- 2. Review notes, so "not approved" can say what to fix.
--
-- The rejection screen told people "Please contact support for more
-- information", which manufactures the support email it was meant to avoid.
-- Almost every real rejection is administrative and fixable - a blurry ID
-- photo, expired insurance - and those people should be told exactly what to
-- redo and be let back in to redo it, not dead-ended on a red screen.
--
-- review_note holds that message. The provider app shows it at the top of the
-- registration flow when they come back, so the answer is waiting for them in
-- the app as well as in their email.
alter table public.providers
  add column if not exists review_note text,
  add column if not exists reviewed_at timestamptz;

comment on column public.providers.review_note is
  'What the applicant must fix, shown to them in-app and emailed. Written by an admin on "Needs attention". Plain, non-accusatory, actionable.';
comment on column public.providers.reviewed_at is
  'When an admin last made a decision on this application.';
