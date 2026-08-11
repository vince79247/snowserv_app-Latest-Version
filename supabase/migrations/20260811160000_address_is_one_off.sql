-- "Ordering for someone else" was quietly changing the customer's OWN address.
--
-- The Checkout webhook inserts that one-off service address with
-- `user_id = <the ordering customer>`, so it lands in the customer's own address
-- list. customer_home.loadAddress() then picks the saved address with
--
--     .eq('user_id', me).limit(1)        -- no ORDER BY
--
-- and LIMIT 1 without ORDER BY returns whatever row Postgres hands back, which
-- moves as rows are updated (the storm-booking geocode cache PATCHes lat/lng, an
-- admin sets price_multiplier, ...). Reproduced on live data 2026-08-11: the
-- account with 13 addresses — one real Yonkers home, twelve left over from
-- "someone else" test orders — resolved to "1 day rd, Bronx".
--
-- The customer would then see a property they once ordered FOR SOMEONE ELSE as
-- their own service address, priced by that property's zone, and order snow
-- removal for the wrong house. (Order notes were never at risk: they are keyed
-- to customer_id AND address_id together, so they stay consistent with whatever
-- address is shown. The address itself was the bug.)
--
-- Fix: mark one-off addresses so they can never be mistaken for the customer's
-- home, and give the table a real timestamp so "the saved one" is a stable,
-- ordered choice instead of a coin flip.

alter table public.addresses
  add column if not exists is_one_off boolean not null default false;

-- No created_at existed, which is also why this could not be ordered out of.
-- Existing rows all collapse to now(); that is fine, because the backfill below
-- resolves the only account where the ordering actually mattered.
alter table public.addresses
  add column if not exists created_at timestamptz not null default now();

comment on column public.addresses.is_one_off is
  'True for a service address created by an "ordering for someone else" order. '
  'It belongs to the ordering customer only so the job can reference it — it is '
  'NOT their home, and customer_home.loadAddress() must never select it.';

-- Partial index: loadAddress only ever asks for a customer''s non-one-off rows.
create index if not exists addresses_user_primary_idx
  on public.addresses (user_id, created_at)
  where is_one_off = false;

-- ---------------------------------------------------------------------------
-- Backfill.
--
-- Keep exactly ONE address per customer and flag the rest, choosing the one to
-- keep by a rule with real meaning rather than a coin flip: a customer's home
-- has to sit in a city we actually serve, or they could never have ordered at
-- it. So the kept row is the one whose city matches an active service area,
-- then the one still referenced by a job or a storm booking, then a stable id.
--
-- On live data that resolves the single affected account exactly right: one
-- "34 Melrose Ave, Yonkers" (kept — Yonkers is the active zone) against twelve
-- Bronx leftovers from "someone else" test orders (flagged). Everyone else has
-- one address and correctly keeps is_one_off = false.
--
-- Nothing is deleted. Flagging is reversible; DELETE is not, and a wrongly
-- flagged row can be corrected with an UPDATE instead of being gone.
-- ---------------------------------------------------------------------------
update public.addresses a
set is_one_off = true
where exists (
        select 1 from public.addresses b
        where b.user_id = a.user_id and b.id <> a.id
      )
  and not exists (select 1 from public.jobs j where j.address_id = a.id)
  and not exists (select 1 from public.storm_bookings s where s.address_id = a.id)
  and a.id <> (
        select keep.id
        from public.addresses keep
        where keep.user_id = a.user_id
        order by
          (exists (select 1 from public.service_areas z
                   where z.is_active
                     and lower(z.name) = lower(coalesce(keep.city, '')))) desc,
          (exists (select 1 from public.jobs j where j.address_id = keep.id)) desc,
          (exists (select 1 from public.storm_bookings s
                   where s.address_id = keep.id)) desc,
          keep.id
        limit 1
      );
