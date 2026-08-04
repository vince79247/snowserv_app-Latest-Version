-- Add a 'pricing' category to address_notes.
--
-- Vince's ask: a provider who arrives and finds the job is worth more than it
-- was priced at should be able to say so, against the PROPERTY, where it will
-- still be true next storm.
--
-- This is the missing half of a lever that already exists. addresses.
-- price_multiplier is the admin's "this property is underpriced" control, but
-- nothing generated the signal to use it — the admin had no way to learn that
-- 14 Elm has a 200ft driveway the zone price doesn't cover. The provider
-- standing on it is the only person who knows, and until now had nowhere to put
-- it. Now: provider flags it -> admin sees it on the job card -> admin taps the
-- address and sets the multiplier -> future orders at that property price
-- correctly.
--
-- Deliberately a NOTE, not a price-change request. The provider is reporting
-- what he sees; the admin decides. A provider can never move a price.

alter table public.address_notes
  drop constraint if exists address_notes_category_check;

alter table public.address_notes
  add constraint address_notes_category_check
  check (category in ('safety', 'access', 'quirk', 'pricing'));
