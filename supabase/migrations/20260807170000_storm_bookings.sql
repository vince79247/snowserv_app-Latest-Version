-- "Book my next storm" — standing order that fires itself when snow stops.
--
-- Vince's idea, 2026-08-07, and the shape of it is his too: "definitely so they
-- could book ahead of time FOR WHEN THE STORM IS DONE."
--
-- That last part is the whole design. The customer does not want plowing at
-- hour two of a ten-hour storm — they want to wake up to a clear driveway. So
-- the trigger is not "it snowed", it is "enough snow has fallen AND it has
-- stopped falling". Firing on accumulation alone would send a provider out to
-- clear a driveway that fills back in by morning, and we would have charged for
-- it. Two conditions, both required.
--
-- ON-DEMAND STAYS THE PITCH (Vince, same conversation): this is the same engine
-- with a trigger on it, offered as a checkbox inside the ordering flow. It is
-- never the headline. The differentiator is still "order it now, watch it
-- happen" — the incumbent is a seasonal contract you sign in October and hope
-- shows up.
--
-- PAYMENT IS DELIBERATELY NOT TAKEN AT BOOKING TIME. A Stripe authorization
-- dies after about 7 days and nobody knows when the next storm is, so holding
-- at booking would guarantee a dead PaymentIntent — the exact failure the
-- stranded-jobs migration exists to prevent. Instead we require a card on file
-- and authorize OFF-SESSION at trigger time, at the prices in force that day.

create table if not exists public.storm_bookings (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.users(id) on delete cascade,
  address_id uuid not null references public.addresses(id) on delete cascade,

  -- Mirrors the order screen exactly, so a booking is just an order waiting for
  -- a trigger. service_type: 'sidewalk' | 'driveway' | 'sidewalk_driveway'.
  service_type text not null,
  salting boolean not null default false,
  driveway_size text,

  -- Fire once this much NEW snow has fallen and stopped. Inches.
  trigger_inches numeric not null default 2,

  -- active → triggered (job created) | cancelled (by customer) | failed (card
  -- declined at trigger time; the customer is told and it stops retrying)
  status text not null default 'active',

  job_id uuid references public.jobs(id) on delete set null,
  triggered_at timestamptz,
  last_checked_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),

  constraint storm_bookings_service_type_check
    check (service_type in ('sidewalk','driveway','sidewalk_driveway')),
  constraint storm_bookings_status_check
    check (status in ('active','triggered','cancelled','failed')),
  -- 1"–12". Below an inch is not worth a truck; above a foot nobody is waiting
  -- for it to "stop" before they want help.
  constraint storm_bookings_trigger_range
    check (trigger_inches >= 1 and trigger_inches <= 12)
);

comment on table public.storm_bookings is
  'Standing snow-removal order that fires when enough snow has fallen AND stopped. Payment is authorized off-session at TRIGGER time, never at booking time - a Stripe auth expires in ~7 days and storms do not schedule themselves.';

create index if not exists storm_bookings_active_idx
  on public.storm_bookings (status) where status = 'active';
create index if not exists storm_bookings_customer_idx
  on public.storm_bookings (customer_id, created_at desc);

-- One active booking per address. Two standing orders on the same driveway
-- would send two providers and charge twice for one storm.
create unique index if not exists storm_bookings_one_active_per_address
  on public.storm_bookings (address_id) where status = 'active';

alter table public.storm_bookings enable row level security;

grant select, insert, update on public.storm_bookings to authenticated;

-- Customers see and manage only their own; admins see everything.
drop policy if exists storm_bookings_select on public.storm_bookings;
create policy storm_bookings_select on public.storm_bookings
  for select to authenticated
  using (customer_id = auth.uid() or is_admin());

drop policy if exists storm_bookings_insert on public.storm_bookings;
create policy storm_bookings_insert on public.storm_bookings
  for insert to authenticated
  with check (customer_id = auth.uid());

-- A customer may CANCEL their own booking. They may not flip one to 'triggered'
-- or point it at a job — only the service role does that, at trigger time.
drop policy if exists storm_bookings_update on public.storm_bookings;
create policy storm_bookings_update on public.storm_bookings
  for update to authenticated
  using (customer_id = auth.uid())
  with check (customer_id = auth.uid() and status in ('active','cancelled'));
