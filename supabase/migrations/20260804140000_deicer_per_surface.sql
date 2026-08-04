-- Deicer priced per surface instead of one flat fee.
--
-- price_salting was a single number added to any job regardless of what was
-- being salted. That was survivable while it was $45. When Yonkers raised it to
-- $90 (material costs), a sidewalk-only order became $80 to shovel plus $90 to
-- salt -- the add-on cost more than the service itself. It was also mispriced on
-- the cost side all along: salting a sidewalk uses meaningfully less salt and
-- less time than salting a sidewalk AND a driveway.
--
-- price_salting KEEPS its existing meaning as the both-surfaces price, so every
-- existing read stays correct and nothing has to be updated in lockstep. The two
-- new columns backfill from it, which makes applying this migration a no-op on
-- what anyone is charged until an admin lowers them in the Zones editor.
--
-- Readers (customer_home, quote_screen, create-checkout-session) still coalesce
-- to price_salting, so a zone row written before these columns existed -- or by
-- anything that misses them -- prices sanely rather than falling to $0.

alter table public.service_areas
  add column if not exists price_salting_sidewalk numeric,
  add column if not exists price_salting_driveway numeric;

update public.service_areas
   set price_salting_sidewalk = coalesce(price_salting_sidewalk, price_salting),
       price_salting_driveway = coalesce(price_salting_driveway, price_salting);
