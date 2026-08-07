-- Stop collecting identity documents. Stripe verifies identity; we don't.
--
-- Vince, 2026-08-07: "Do we really even need an ID? Isn't that something Stripe
-- might ask for? Because at the end of the day, it's Stripe that's issuing the
-- payment to them."
--
-- He's right, and we were already halfway there. Connect Express onboarding
-- (#21, July) collects and verifies legal name, date of birth, home address,
-- SSN and bank details, checked against government records, before Stripe will
-- move a cent — and Stripe asks for a photo ID ITSELF when its automated check
-- can't match. That's why SSN/DOB/bank were dropped from this table back then.
-- Keeping our own ID copy was the leftover half of a migration we'd already
-- decided the principle of.
--
-- What it actually bought: an admin looking at a photo, which is not
-- verification. What it cost: license numbers in plaintext and ID images in
-- storage — under NY's SHIELD Act, "private information" whose breach carries a
-- notification duty. The riskiest data we touch, for the weakest check we run.
--
-- The verified identity is still available to us. As the platform that created
-- these accounts we can read the verified legal name, DOB and address from
-- GET /v1/accounts/{id} or the Stripe Dashboard under Connected accounts — no
-- request to anyone. Only the full SSN and any ID scan stay with Stripe, and
-- those are things you'd hand to police, not use to settle a dispute. Better
-- they sit there than in a database of ours that can be breached.
--
-- GOING ONLINE IS NOW GATED ON payouts_enabled, which is the other half of
-- this. That gate was worth adding on its own: batch-payouts already skipped
-- anyone without it, so before today a provider could go online, work an entire
-- storm, and silently never be paid.
--
-- Data purged at the same time as this migration (verified 0 remaining):
--   * 2 provider rows had dl_number / dl_state / dl_photo_url / id_type -> null
--   * 4 objects in the provider-documents bucket, all dl_* -> deleted via the
--     Storage API. No ins_* objects existed, so insurance photos were untouched.
--
-- The COLUMNS are not dropped. Build 16 is on TestFlight and on Vince's phone,
-- and it still writes dl_number/dl_state/dl_photo_url on submit; dropping them
-- would make registration fail outright for anyone who hasn't updated. Drop
-- them once build 17+ is the floor in the field.

comment on column public.providers.dl_number is
  'DEPRECATED 2026-08-07 - no longer collected. Identity is verified by Stripe Connect. Kept (nulled) only because build 16 still writes it; drop once 17+ is the floor.';
comment on column public.providers.dl_state is
  'DEPRECATED 2026-08-07 - see dl_number.';
comment on column public.providers.dl_photo_url is
  'DEPRECATED 2026-08-07 - see dl_number. All objects purged from provider-documents.';
comment on column public.providers.id_type is
  'DEPRECATED 2026-08-07 - shipped and withdrawn the same day; identity moved to Stripe entirely.';
